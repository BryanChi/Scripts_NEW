-- @description BRYAN Script Installer - Mini ReaPack Alternative
-- @version 1.1.1
-- @author bryan
-- @about Downloads and installs scripts, JSFX, and assets from GitHub repo. Automatically registers scripts in Action List.
-- @changelog Prefix installed action scripts with CRS_ so they stay distinct from local dev copies

local r = reaper

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

-- GitHub repositories configuration
-- Define multiple repositories here. Each repo has a unique key/name.
local REPOSITORIES = {
    -- Default/main repository
    main = {
        user = "BryanChi",      -- GitHub username
        repo = "Vertical-FX-List",         -- Repository name
        branch = "main",         -- Branch name (main, master, etc.)
        display = "Vertical FX List",
        action_names = { "Vertical FX List" },
        license_section = "FXD_Vertical_FX_List_License",
    },
    sample_map = {
        user = "BryanChi",
        repo = "Sample-Map",
        branch = "main",
        display = "Sample Map",
        action_names = { "Sample Map Browser", "Sample Map - Quick swap for selected item" },
        license_section = "Sample_Map_License",
    },
    stem_split = {
        user = "BryanChi",
        repo = "Stem-Split",
        branch = "main",
        display = "Split to Stems",
        action_names = { "Split selected item to stems", "Tempo map from drum stem" },
    },
}

local LICENSE_VERIFY_URL = "https://www.coolreaperscripts.com/api/license/verify"

-- Selected commits per repository (commit hash or branch name)
local SELECTED_COMMITS = {}

-- Extract version number from commit message
-- Looks for patterns like ##Ver0.8## or ##Ver0.81## in the commit message
-- Returns the version string (e.g., "0.8", "0.81") or nil if not found
local function ExtractVersionFromMessage(commit_message)
    if not commit_message then return nil end
    
    -- Pattern: ##Ver followed by digits and dots, then ##
    -- Examples: ##Ver0.8##, ##Ver0.81##, ##Ver1.0##, ##Ver2.5.1##
    local pattern = "##Ver([%d%.]+)##"
    local version = commit_message:match(pattern)
    
    return version
end

-- Helper function to build raw GitHub URL for a repository
local function GetRepoRawBase(repo_key)
    local repo = REPOSITORIES[repo_key]
    if not repo then
        -- Fallback to first repo if key not found
        local first_key = next(REPOSITORIES)
        repo = REPOSITORIES[first_key]
    end
    
    -- Use selected commit if available, otherwise use branch
    local ref = SELECTED_COMMITS[repo_key] or repo.branch
    
    return string.format("https://raw.githubusercontent.com/%s/%s/%s", 
                         repo.user, repo.repo, ref)
end

-- Helper function to create file entry (Vertical FX List / main repo)
local function CreateFileEntry(url_path, script_type)
    return {
        url_path = url_path,
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/" .. url_path,
        script_type = script_type,
        repo = "main",
    }
end

-- Sample Map files install next to the Lua (SCRIPT_DIR) except JSFX → Effects/
local SAMPLE_MAP_INSTALL_DIR = "Scripts/CoolReaperScripts/Sample Map/"

local function CreateSampleMapFileEntry(url_path, script_type)
    local target_path = url_path
    if not url_path:match("^Effects/") then
        target_path = SAMPLE_MAP_INSTALL_DIR .. url_path
    end
    return {
        url_path = url_path,
        target_path = target_path,
        script_type = script_type,
        repo = "sample_map",
    }
end

local function GetSampleMapFiles()
    local files = {}

    -- Scripts registered in the Action List
    table.insert(files, CreateSampleMapFileEntry("Sample Map Browser.lua", "lua"))
    table.insert(files, CreateSampleMapFileEntry("Sample Map - Quick swap for selected item.lua", "lua"))

    -- Sidecars: copy only (do not register Python / tag palettes as actions)
    table.insert(files, CreateSampleMapFileEntry("SampleMapAnalyzer.py", "asset"))
    table.insert(files, CreateSampleMapFileEntry("SampleMapDrumAI.py", "asset"))
    table.insert(files, CreateSampleMapFileEntry("SampleMapGrooveMIDI.py", "asset"))
    table.insert(files, CreateSampleMapFileEntry("tag_presets.lua", "asset"))
    table.insert(files, CreateSampleMapFileEntry("SampleMapUpdate.lua", "asset"))

    -- JSFX (REAPER Effects folder)
    table.insert(files, CreateSampleMapFileEntry("Effects/SampleMapMIDI.jsfx", "jsfx"))
    table.insert(files, CreateSampleMapFileEntry("Effects/SampleMapPlayer.jsfx", "jsfx"))
    table.insert(files, CreateSampleMapFileEntry("Effects/SampleMapPreview.jsfx", "jsfx"))

    -- Icon attribution + mapping
    table.insert(files, CreateSampleMapFileEntry("assets/behringer-icons/ATTRIBUTION.md", "asset"))
    table.insert(files, CreateSampleMapFileEntry("assets/behringer-icons/LICENSE", "asset"))
    table.insert(files, CreateSampleMapFileEntry("assets/behringer-icons/role_map.json", "asset"))

    for i = 1, 74 do
        table.insert(files, CreateSampleMapFileEntry("assets/behringer-icons/png/" .. i .. ".png", "asset"))
    end
    local named_behringer = {
        "808", "bass", "clap", "crash", "default", "drum", "fx", "guitar", "hat",
        "keys", "kick", "lead", "loop", "pad", "perc", "pluck", "ride", "rim",
        "snap", "snare", "tom", "vocal",
    }
    for _, name in ipairs(named_behringer) do
        table.insert(files, CreateSampleMapFileEntry("assets/behringer-icons/png/" .. name .. ".png", "asset"))
    end

    local seq_images = {
        "seq-region-parent.png",
        "seq-region-parent-dots.png",
        "seq-region-parent-drum.png",
        "seq-region-parent-led.png",
        "seq-region-parent-notes.png",
        "seq-region-parent-tape.png",
        "seq-region-parent-tile.png",
        "seq-region-parent-wave.png",
    }
    for _, filename in ipairs(seq_images) do
        table.insert(files, CreateSampleMapFileEntry("assets/" .. filename, "asset"))
    end

    local vfx_icons = {
        "camera.png", "copy.png", "folder.png", "folder_open.png", "graph.png",
        "hide.png", "link.png", "receive.png", "search.png", "send.png",
        "settings.png", "show.png", "snapshot.png", "star.png", "starHollow.png",
        "trash.png", "undo.png", "update.png", "volume.png",
    }
    for _, filename in ipairs(vfx_icons) do
        table.insert(files, CreateSampleMapFileEntry("assets/vertical-fx-icons/" .. filename, "asset"))
    end

    return files
end

-- Stem Split files (BryanChi/Stem-Split) — Lua + Python sidecar; venv is created after download
local STEM_SPLIT_INSTALL_DIR = "Scripts/CoolReaperScripts/Stem Split/"

local function CreateStemSplitFileEntry(url_path, script_type)
    return {
        url_path = url_path,
        target_path = STEM_SPLIT_INSTALL_DIR .. url_path,
        script_type = script_type,
        repo = "stem_split",
    }
end

local function GetStemSplitFiles()
    return {
        CreateStemSplitFileEntry("Split selected item to stems.lua", "lua"),
        CreateStemSplitFileEntry("Tempo map from drum stem.lua", "lua"),
        CreateStemSplitFileEntry("StemSplit.py", "asset"),
        CreateStemSplitFileEntry("requirements.txt", "asset"),
    }
end

-- Function to automatically generate Resources folder file list
-- Excludes: fx_category_cache.lua, plugin_select_counts.txt, and the three FX data files
local function GetResourcesFiles()
    local files = {}
    
    -- Files to exclude (relative to Resources folder or full path)
    local excluded = {
        "fx_category_cache.lua",
        "plugin_select_counts.txt",
        "Vertical FX List Resources/Functions/FX_DEV_LIST_FILE.txt",
        "Vertical FX List Resources/Functions/FX_CAT_FILE.txt",
        "Vertical FX List Resources/Functions/FX_LIST.txt",
    }
    
    -- Helper to check if file should be excluded
    local function IsExcluded(file_path)
        for _, excl in ipairs(excluded) do
            if file_path == excl or file_path:match(excl .. "$") then
                return true
            end
        end
        return false
    end
    
    -- Helper to detect script type from extension
    local function GetScriptTypeFromPath(path)
        local ext = path:match("%.([^%.]+)$")
        if ext then
            ext = ext:lower()
            if ext == "lua" then return "lua"
            elseif ext == "eel" then return "eel"
            elseif ext == "py" then return "py"
            elseif ext == "jsfx" then return "jsfx"
            end
        end
        return nil -- Auto-detect for other files
    end
    
    -- Root Resources folder files
    local root_files = {
        "camera.png",
        "copy.png",
        "folder_open.png",
        "folder.png",
        "graph.png",
        "hide.png",
        "link.png",
        "receive.png",
        "search.png",
        "send.png",
        "settings.png",
        "show.png",
        "snapshot.png",
        "star.png",
        "starHollow.png",
        "trash.png",
        "undo.png",
        "update.png",
        "volume.png",
    }
    
    -- Functions folder files
    local function_files = {
        "AndaleMonoVertical.ttf",
        "FX Buttons.lua",
        "FX Parser.lua",
        "General Functions.Lua",
        "Sends.lua",
        "Update.lua",
    }
    
    -- Add root files
    for _, filename in ipairs(root_files) do
        local url_path = "Vertical FX List Resources/" .. filename
        if not IsExcluded(url_path) then
            table.insert(files, CreateFileEntry(url_path, GetScriptTypeFromPath(filename)))
        end
    end
    
    -- Add function files
    for _, filename in ipairs(function_files) do
        local url_path = "Vertical FX List Resources/Functions/" .. filename
        if not IsExcluded(url_path) then
            table.insert(files, CreateFileEntry(url_path, GetScriptTypeFromPath(filename)))
        end
    end
    
    return files
end

-- File list: {url_path, target_path, script_type, repo}
-- url_path: path relative to repo root (e.g., "Scripts/MyTool.lua")
-- target_path: path relative to REAPER resource folder (e.g., "Scripts/MyTool.lua")
-- script_type: "lua", "eel", "py", "jsfx", "asset", or nil (auto-detect from extension)
-- repo: repository key from REPOSITORIES table (optional, defaults to first repo)
local FILES_TO_INSTALL = {
    -- Main script
    {
        url_path = "FXD_Vertical FX list.lua",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/FXD_Vertical FX list.lua",
        script_type = "lua",
        repo = "main",
    },
    
    -- Configuration files
    {
        url_path = "style_presets_FACTORY.lua",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/style_presets_FACTORY.lua",
        script_type = "lua",
        repo = "main",
    },
}

-- Automatically add all Resources folder files (excluding specified files)
local resources_files = GetResourcesFiles()
for _, file_entry in ipairs(resources_files) do
    table.insert(FILES_TO_INSTALL, file_entry)
end

-- Sample Map Browser (BryanChi/Sample-Map)
local sample_map_files = GetSampleMapFiles()
for _, file_entry in ipairs(sample_map_files) do
    table.insert(FILES_TO_INSTALL, file_entry)
end

-- Split to Stems (BryanChi/Stem-Split)
local stem_split_files = GetStemSplitFiles()
for _, file_entry in ipairs(stem_split_files) do
    table.insert(FILES_TO_INSTALL, file_entry)
end

-- Commit selection GUI state (define early so installers can update it)
local commit_gui_state = {
    open = true,
    ctx = nil,
    commits = {},
    releases = {}, -- GitHub releases
    use_releases = false, -- Whether to use releases or commits
    selected_commits = {}, -- {repo_key = commit_sha}
    selected_releases = {}, -- {repo_key = release_tag}
    loading = false,
    error_msg = nil,
    current_repo_index = 1,
    repos_to_select = {},
    selected_repos = {}, -- [repo_key] = true when ticked for install
    repo_ui = {}, -- [repo_key] = { loading, error_msg, use_releases, releases, commits }
    title_font = nil, -- Bold font for title
    -- Installation progress
    installing = false,
    install_progress = 0.0, -- 0.0 to 1.0
    install_current_file = "",
    install_status = "", -- "Downloading", "Installing", "Registering", etc.
    install_success_count = 0,
    install_failed_count = 0,
    install_total = 0,
    install_log = {}, -- List of {file = "filename", status = "success"/"failed", message = "status message"}
    install_log_expanded = false, -- Whether the installation log is expanded
    -- Private standalone Python (python-build-standalone, no PATH / no admin)
    python_path = "",
    python_version = "",
    -- Modal popup
    show_modal = false,
    modal_title = "",
    modal_message = "",
    modal_type = "success", -- "success" or "error"
    license_ui = {}, -- [repo_key] = { label, bg, fg, tooltip, status }
}

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

local function GetResourcePath()
    return r.GetResourcePath()
end

local function GetPathSeparator()
    if r.GetOS():match("Win") then
        return "\\"
    else
        return "/"
    end
end

local function NormalizePath(path)
    local sep = GetPathSeparator()
    return path:gsub("/", sep):gsub("\\", sep)
end

local function GetDirectoryFromPath(filepath)
    local sep = GetPathSeparator()
    local dir = filepath:match("^(.+)" .. sep .. "[^" .. sep .. "]+$")
    return dir or ""
end

local function EnsureDirectoryExists(dir_path)
    if dir_path == "" or dir_path == nil then
        return true
    end
    local normalized = NormalizePath(dir_path)
    local success = r.RecursiveCreateDirectory(normalized, 0)
    return success ~= nil
end

local function GetFileExtension(filename)
    return filename:match("%.([^%.]+)$")
end

local function DetectScriptType(filepath)
    local ext = GetFileExtension(filepath):lower()
    if ext == "lua" then return "lua"
    elseif ext == "eel" then return "eel"
    elseif ext == "py" then return "py"
    elseif ext == "jsfx" then return "jsfx"
    else return "asset"
    end
end

-- Installed action scripts get a CRS_ filename so they sit next to (and don't
-- overwrite) in-development copies. Companions loaded by hardcoded names stay
-- unprefixed: Python sidecars, JSFX, tag_presets.lua, SampleMapUpdate.lua,
-- Vertical FX List Resources, style_presets_FACTORY.lua.
local CRS_SKIP_FILENAMES = {
    ["style_presets_FACTORY.lua"] = true,
}

local function BasenameOf(path)
    return (path and path:match("([^/\\]+)$")) or path or ""
end

local function ReplaceBasename(path, new_name)
    local name = BasenameOf(path)
    if name == "" or name == path then
        return new_name
    end
    return path:sub(1, #path - #name) .. new_name
end

local function ShouldCRSPrefix(file_info)
    local target = file_info.target_path or file_info.url_path or ""
    local script_type = file_info.script_type or DetectScriptType(target)
    if script_type ~= "lua" and script_type ~= "eel" and script_type ~= "py" then
        return false
    end
    if target:match("Resources") or target:match("Functions") then
        return false
    end
    local name = BasenameOf(target)
    if CRS_SKIP_FILENAMES[name] or name:match("^CRS_") then
        return false
    end
    return true
end

local function ResolveInstallTarget(file_info)
    local target = file_info.target_path or file_info.url_path
    if not ShouldCRSPrefix(file_info) then
        return target
    end
    local name = BasenameOf(target)
    local new_name
    if name == "FXD_Vertical FX list.lua" then
        new_name = "CRS_vertical fx list.lua"
    else
        new_name = "CRS_" .. name
    end
    return ReplaceBasename(target, new_name)
end

local function IsVerticalFXListMain(file_info)
    local url = file_info.url_path or ""
    return url:match("FXD_Vertical FX list%.lua$") ~= nil
end

-- ============================================================================
-- DOWNLOAD FUNCTIONS
-- ============================================================================

-- URL encode function - converts spaces and special characters to URL-safe format
-- GitHub raw URLs need spaces encoded as %20
local function URLEncode(str)
    if not str then return "" end
    -- Encode each path segment separately
    local parts = {}
    for part in str:gmatch("([^/]+)") do
        -- Encode all special characters at once, including spaces
        -- This prevents double-encoding issues
        part = part:gsub("([^%w%-%.%_%~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
        table.insert(parts, part)
    end
    return table.concat(parts, "/")
end

-- Download file directly to disk (handles binary files correctly, much faster)
local function DownloadFileToDisk(url, output_path)
    local OS = r.GetOS()
    local cmd
    local sep = GetPathSeparator()
    
    -- Ensure download directory exists
    local download_dir = GetDirectoryFromPath(output_path)
    if download_dir ~= "" then
        EnsureDirectoryExists(download_dir)
    end
    
    -- Use curl to download directly to file (handles binary correctly, much faster)
    -- -L follows redirects, -f fails on HTTP errors, -s silent, -S show errors, -o output file
    -- Use double quotes and proper escaping to handle paths with spaces and special characters
    if OS:match("Win") then
        -- Windows: escape the output path properly for cmd
        local escaped_path = output_path:gsub('"', '\\"')
        cmd = string.format('curl -L -f -s -S -o "%s" "%s" 2>&1', escaped_path, url)
    else
        -- macOS/Linux: use full path to curl, escape single quotes properly
        -- Use double quotes for the path to handle spaces and apostrophes
        local escaped_path = output_path:gsub('"', '\\"')
        cmd = string.format('/usr/bin/curl -L -f -s -S -o "%s" "%s" 2>&1', escaped_path, url)
    end
    
    -- Execute curl (downloads directly to file)
    -- Use shorter timeout for small files (10 seconds should be plenty)
    local result = r.ExecProcess(cmd, 10000) -- 10 second timeout
    
    -- Check if file was created and has content first (curl might output errors but still succeed)
    local file = io.open(output_path, "rb")
    if file then
        local size = file:seek("end")
        file:close()
        
        -- If file exists and has content, consider it successful (even if curl output errors)
        if size > 0 then
            return true, nil
        end
    end
    
    -- File doesn't exist or is empty - check for errors in curl output
    if result then
        -- Only treat as error if it's a clear curl error message
        if result:match("^curl: %(") or result:match("curl: %(3%)") or 
           result:match("curl: %(6%)") or result:match("curl: %(22%)") or
           result:match("curl: %(404%)") then
            return false, result
        end
        -- If result contains error-like text but file doesn't exist, it's an error
        if result:match("404") or result:match("Not Found") or result:match("Could not resolve") then
            return false, result
        end
    end
    
    -- File doesn't exist and no clear error - still an error
    return false, "Download failed: file not created or empty"
end

local function DownloadFileWithProgress(url, output_path, progress_callback)
    if progress_callback then
        progress_callback("Downloading to: " .. output_path)
    end
    
    local success, error_msg = DownloadFileToDisk(url, output_path)
    
    if progress_callback then
        if success then
            progress_callback("Downloaded successfully")
        else
            progress_callback("Download failed: " .. (error_msg or "unknown"))
        end
    end
    
    if not success then
        return nil, error_msg
    end
    
    -- Read the file content
    local file = io.open(output_path, "rb")
    if not file then
        return nil, "Failed to read downloaded file"
    end
    
    local content = file:read("*all")
    file:close()
    
    return content, nil
end

-- ============================================================================
-- INSTALLATION FUNCTIONS
-- ============================================================================

local function WriteFile(filepath, content)
    local normalized_path = NormalizePath(filepath)
    
    -- Ensure directory exists
    local dir = GetDirectoryFromPath(normalized_path)
    if dir ~= "" then
        if not EnsureDirectoryExists(dir) then
            return false, "Failed to create directory: " .. dir
        end
    end
    
    -- Write file
    local file = io.open(normalized_path, "wb")
    if not file then
        return false, "Failed to open file for writing: " .. normalized_path
    end
    
    file:write(content)
    file:close()
    
    return true, nil
end

local function RegisterScript(filepath, script_type)
    script_type = script_type or DetectScriptType(filepath)
    
    -- Only register Lua, EEL, and Python scripts
    if script_type ~= "lua" and script_type ~= "eel" and script_type ~= "py" then
        return false, "Not a registerable script type"
    end
    
    -- Normalize the path
    local normalized_path = NormalizePath(filepath)
    local resource_path = GetResourcePath()
    local sep = GetPathSeparator()
    
    -- Convert absolute path to relative path (REAPER expects relative to resource folder)
    local relative_path = normalized_path
    if normalized_path:match("^" .. resource_path:gsub("([%(%)%.%+%-%*%?%[%^%$%%])", "%%%1")) then
        -- Path is absolute and starts with resource path, make it relative
        relative_path = normalized_path:sub(#resource_path + 2) -- +2 to skip separator
        relative_path = relative_path:gsub(sep, "/") -- Use forward slashes for REAPER
    elseif normalized_path:match("^/") or normalized_path:match("^[A-Za-z]:") then
        -- Absolute path but not under resource folder - keep as is, REAPER might handle it
        relative_path = normalized_path
    else
        -- Already relative, ensure forward slashes
        relative_path = relative_path:gsub(sep, "/")
    end
    
    -- Verify file exists before trying to register (use absolute path for check)
    local abs_path = normalized_path
    if not abs_path:match("^/") and not abs_path:match("^[A-Za-z]:") then
        abs_path = resource_path .. sep .. abs_path
    end
    abs_path = NormalizePath(abs_path)
    
    local file_check = io.open(abs_path, "rb")
    if not file_check then
        return false, "File does not exist: " .. abs_path
    end
    file_check:close()
    
    -- Determine section ID based on script type
    -- 0 = Main section (ReaScript)
    local section_id = 0
    
    -- Add script to action list
    -- Parameters: add (true), section (0 = main), path (relative to resource folder), commit (true)
    -- Returns: command ID (>0) on success, 0 on failure
    local command_id = r.AddRemoveReaScript(true, section_id, relative_path, true)
    
    if command_id and command_id > 0 then
        return true, nil
    else
        -- Try absolute path as fallback
        command_id = r.AddRemoveReaScript(true, section_id, abs_path, true)
        if command_id and command_id > 0 then
            return true, nil
        else
            local error_msg = "Failed to register script (tried both paths, returned: " .. tostring(command_id) .. ")"
            return false, error_msg
        end
    end
end

-- Download and extract zip archive from GitHub release
local function DownloadAndExtractZip(zip_url, progress_callback)
    local OS = r.GetOS()
    local sep = GetPathSeparator()
    local resource_path = GetResourcePath()
    
    -- Create temp directory
    local temp_dir = resource_path .. sep .. "Scripts" .. sep .. "CoolReaperScripts" .. sep .. "TEMP"
    EnsureDirectoryExists(temp_dir)
    
    local zip_path = temp_dir .. sep .. "release.zip"
    
    if progress_callback then
        progress_callback("Downloading release archive...")
    end
    
    -- Download zip file
    local cmd
    if OS:match("Win") then
        local escaped_path = zip_path:gsub('"', '\\"')
        cmd = string.format('curl -L -f -s -S -o "%s" "%s"', escaped_path, zip_url)
    else
        local escaped_path = zip_path:gsub('"', '\\"')
        cmd = string.format('/usr/bin/curl -L -f -s -S -o "%s" "%s"', escaped_path, zip_url)
    end
    
    local result = r.ExecProcess(cmd, 120000) -- 120 second timeout for larger files
    
    -- Check if download succeeded
    local file = io.open(zip_path, "rb")
    if not file then
        return nil, "Failed to download zip file"
    end
    local size = file:seek("end")
    file:close()
    
    if size == 0 then
        return nil, "Downloaded zip file is empty"
    end
    
    if progress_callback then
        progress_callback("Extracting archive...")
    end
    
    -- Extract zip file
    local extract_cmd
    local extracted_folder = temp_dir .. sep .. "extracted"
    EnsureDirectoryExists(extracted_folder)
    
    if OS:match("Win") then
        -- Windows: use PowerShell Expand-Archive
        local escaped_zip = zip_path:gsub('"', '\\"')
        local escaped_dest = extracted_folder:gsub('"', '\\"')
        extract_cmd = string.format('powershell -Command "Expand-Archive -Path \\"%s\\" -DestinationPath \\"%s\\" -Force"', escaped_zip, escaped_dest)
    else
        -- macOS/Linux: use unzip
        extract_cmd = string.format('cd "%s" && /usr/bin/unzip -q -o "%s" -d "%s"', temp_dir, zip_path, extracted_folder)
    end
    
    local extract_result = r.ExecProcess(extract_cmd, 60000) -- 60 second timeout
    -- Retry with a longer timeout if extraction timed out
    if extract_result == "-999" then
        if progress_callback then
            progress_callback("Extraction timed out, retrying...")
        end
        extract_result = r.ExecProcess(extract_cmd, 180000) -- 3 minute timeout
    end
    
    -- Find the extracted folder (GitHub zipballs create a folder like repo-tag/)
    -- Enumerate directories in extracted_folder
    local found_folder = nil
    for i = 0, 100 do
        local subdir = r.EnumerateSubdirectories(extracted_folder, i)
        if not subdir then break end
        found_folder = extracted_folder .. sep .. subdir
        break -- Take first directory
    end
    
    -- If no subdirectory found, use extracted_folder itself
    if not found_folder then
        found_folder = extracted_folder
    end
    
    if progress_callback then
        progress_callback("Archive extracted successfully")
    end
    
    return found_folder, nil
end

-- Install files from extracted release folder
local function InstallFromRelease(extracted_folder, progress_callback, file_list)
    local resource_path = GetResourcePath()
    local sep = GetPathSeparator()
    local results = {success = {}, failed = {}}
    if not file_list or #file_list == 0 then
        file_list = FILES_TO_INSTALL
    end
    
    for _, file_info in ipairs(file_list) do
        local url_path = file_info.url_path
        local target_path = file_info.target_path
        local script_type = file_info.script_type
        
        -- Build source path in extracted folder
        -- GitHub zipballs preserve the repo structure
        local source_path = extracted_folder .. sep .. url_path:gsub("/", sep)
        
        -- Build destination path
        local dest_path = resource_path .. sep .. NormalizePath(target_path)
        
        if progress_callback then
            progress_callback("Installing: " .. url_path)
        end
        
        -- Check if source file exists
        local source_file = io.open(source_path, "rb")
        if not source_file then
            table.insert(results.failed, {path = url_path, error = "File not found in release"})
            if progress_callback then
                progress_callback("Failed: " .. url_path .. " (not found)")
            end
            goto continue
        end
        source_file:close()
        
        -- Special handling for Vertical FX List script
        local filename = target_path:match("([^/\\]+)$") or url_path:match("([^/\\]+)$")
        local dest_target = ResolveInstallTarget(file_info)
        dest_path = resource_path .. sep .. NormalizePath(dest_target)
        local is_vertical_fx_list = IsVerticalFXListMain(file_info)
        
        if is_vertical_fx_list then
            -- Install directly to CoolReaperScripts/Vertical FX List folder with different name
            local bryan_scripts_folder = resource_path .. sep .. "Scripts" .. sep .. "CoolReaperScripts" .. sep .. "Vertical FX List"
            EnsureDirectoryExists(bryan_scripts_folder)
            local final_path = bryan_scripts_folder .. sep .. "CRS_vertical fx list.lua"
            
            local copy_success, copy_error = CopyFile(source_path, final_path)
            if copy_success then
                table.insert(results.success, url_path)
                
                -- Register script
                script_type = script_type or DetectScriptType(target_path)
                if script_type == "lua" or script_type == "eel" or script_type == "py" then
                    RegisterScript(final_path, script_type)
                end
            else
                table.insert(results.failed, {path = url_path, error = copy_error or "Copy failed"})
            end
        else
            -- Check if file already exists - skip if it does (don't overwrite)
            local existing_file = io.open(dest_path, "rb")
            if existing_file then
                existing_file:close()
                if progress_callback then
                    progress_callback("Skipping (exists): " .. target_path)
                end
                table.insert(results.success, url_path)
                goto continue
            end
            
            -- Copy file
            local copy_success, copy_error = CopyFile(source_path, dest_path)
            if copy_success then
                table.insert(results.success, url_path)
                
                -- Register script if applicable
                script_type = script_type or DetectScriptType(target_path)
                if script_type == "lua" or script_type == "eel" or script_type == "py" then
                    RegisterScript(dest_path, script_type)
                end
            else
                table.insert(results.failed, {path = url_path, error = copy_error or "Copy failed"})
            end
        end
        
        ::continue::
    end
    
    return results
end

-- Copy file from source to destination
local function CopyFile(source_path, dest_path)
    local source_file = io.open(source_path, "rb")
    if not source_file then
        return false, "Failed to open source file: " .. source_path
    end
    
    local content = source_file:read("*all")
    source_file:close()
    
    -- Ensure destination directory exists
    local dest_dir = GetDirectoryFromPath(dest_path)
    if dest_dir ~= "" then
        EnsureDirectoryExists(dest_dir)
    end
    
    local dest_file = io.open(dest_path, "wb")
    if not dest_file then
        return false, "Failed to open destination file: " .. dest_path
    end
    
    dest_file:write(content)
    dest_file:close()
    
    return true, nil
end

-- Download and extract zip archive from GitHub release
local function DownloadAndExtractZip(zip_url, progress_callback)
    local OS = r.GetOS()
    local sep = GetPathSeparator()
    local resource_path = GetResourcePath()
    
    -- Create temp directory
    local temp_dir = resource_path .. sep .. "Scripts" .. sep .. "CoolReaperScripts" .. sep .. "TEMP"
    EnsureDirectoryExists(temp_dir)
    
    local zip_path = temp_dir .. sep .. "release.zip"
    
    -- Download zip file
    if progress_callback then
        progress_callback("Downloading release archive...")
    end
    
    local cmd
    if OS:match("Win") then
        local escaped_path = zip_path:gsub('"', '\\"')
        cmd = string.format('curl -L -f -s -S -o "%s" "%s" 2>&1', escaped_path, zip_url)
    else
        local escaped_path = zip_path:gsub('"', '\\"')
        cmd = string.format('/usr/bin/curl -L -f -s -S -o "%s" "%s" 2>&1', escaped_path, zip_url)
    end
    
    local result = r.ExecProcess(cmd, 120000) -- 120 second timeout for larger files
    
    -- Check if download succeeded
    local file = io.open(zip_path, "rb")
    if not file then
        return nil, "Failed to download zip file"
    end
    local size = file:seek("end")
    file:close()
    
    if size == 0 then
        return nil, "Downloaded zip file is empty"
    end
    
    if progress_callback then
        progress_callback("Extracting archive...")
    end
    
    -- Extract zip file
    local extract_dir = temp_dir .. sep .. "extracted"
    EnsureDirectoryExists(extract_dir)
    
    local extract_cmd
    if OS:match("Win") then
        -- Windows: use PowerShell Expand-Archive
        local escaped_zip = zip_path:gsub('"', '\\"')
        local escaped_extract = extract_dir:gsub('"', '\\"')
        extract_cmd = string.format('powershell -Command "Expand-Archive -Path \\"%s\\" -DestinationPath \\"%s\\" -Force"', escaped_zip, escaped_extract)
    else
        -- macOS: use ditto (more reliable than unzip)
        -- Linux: use unzip
        if OS:match("OSX") or OS:match("macOS") then
            extract_cmd = string.format('/usr/bin/ditto -xk "%s" "%s"', zip_path, extract_dir)
        else
            extract_cmd = string.format('/usr/bin/unzip -q -o "%s" -d "%s"', zip_path, extract_dir)
        end
    end
    
    local extract_result = r.ExecProcess(extract_cmd, 120000) -- 2 minute timeout
    
    -- Check if extraction timed out
    if extract_result == "-999" then
        return nil, "Extraction timed out after 2 minutes"
    end
    
    -- Find the extracted folder (GitHub zipballs create a folder like repo-tag/)
    -- First try subdirectories (most common case)
    local extracted_folder = nil
    for i = 0, 100 do
        local subdir = r.EnumerateSubdirectories(extract_dir, i)
        if not subdir then break end
        extracted_folder = extract_dir .. sep .. subdir
        break -- Take first subdirectory
    end
    
    -- If no subdirectory found, check if extract_dir itself contains files (unlikely but possible)
    if not extracted_folder then
        local has_files = false
        for i = 0, 10 do
            local file_name = r.EnumerateFiles(extract_dir, i)
            if file_name then
                has_files = true
                break
            end
        end
        if has_files then
            extracted_folder = extract_dir
        end
    end
    
    if not extracted_folder then
        local err = "Failed to find extracted folder"
        if extract_result and extract_result ~= "" then
            err = err .. " (extract output: " .. extract_result .. ")"
        end
        return nil, err
    end
    
    return extracted_folder, nil
end

-- Install files from extracted release archive
local function InstallFromRelease(extracted_folder, progress_callback, file_list)
    local resource_path = GetResourcePath()
    local sep = GetPathSeparator()
    local results = {success = {}, failed = {}}
    if not file_list or #file_list == 0 then
        file_list = FILES_TO_INSTALL
    end
    
    for _, file_info in ipairs(file_list) do
        local url_path = file_info.url_path
        local target_path = file_info.target_path
        local script_type = file_info.script_type
        
        -- Build source path in extracted folder
        local source_path = extracted_folder .. sep .. url_path:gsub("/", sep)
        
        -- Check if source file exists
        local source_file = io.open(source_path, "rb")
        if not source_file then
            table.insert(results.failed, {path = url_path, error = "File not found in release archive"})
            if progress_callback then
                progress_callback("Skipping (not found): " .. url_path)
            end
            goto continue
        end
        source_file:close()
        
        -- Build final target path (CRS_ prefix on action scripts)
        local dest_target = ResolveInstallTarget(file_info)
        local full_target = resource_path .. sep .. NormalizePath(dest_target)
        
        -- Get filename
        local filename = BasenameOf(dest_target)
        local is_vertical_fx_list = IsVerticalFXListMain(file_info)
        
        -- Special handling for Vertical FX List script
        if is_vertical_fx_list then
            local bryan_scripts_folder = resource_path .. sep .. "Scripts" .. sep .. "CoolReaperScripts" .. sep .. "Vertical FX List"
            EnsureDirectoryExists(bryan_scripts_folder)
            full_target = bryan_scripts_folder .. sep .. "CRS_vertical fx list.lua"
        end
        
        -- Copy file from extracted folder to target location
        if progress_callback then
            progress_callback("Installing: " .. url_path)
        end
        
        -- For non-Vertical FX List files, check if already exists
        if not is_vertical_fx_list then
            local existing_file = io.open(full_target, "rb")
            if existing_file then
                existing_file:close()
                if progress_callback then
                    progress_callback("Skipping (already exists): " .. dest_target)
                end
                table.insert(results.success, url_path)
                goto continue
            end
        end
        
        local copy_success, copy_error = CopyFile(source_path, full_target)
        if not copy_success then
            table.insert(results.failed, {path = url_path, error = copy_error or "Copy failed"})
            if progress_callback then
                progress_callback("Failed: " .. url_path)
            end
            goto continue
        end
        
        -- Register script if applicable
        script_type = script_type or DetectScriptType(target_path)
        if script_type == "lua" or script_type == "eel" or script_type == "py" then
            if progress_callback then
                if is_vertical_fx_list then
                    progress_callback("Registering CRS_vertical fx list.lua")
                else
                    progress_callback("Registering: " .. dest_target)
                end
            end
            
            local reg_success, reg_error = RegisterScript(full_target, script_type)
            if not reg_success then
                if progress_callback then
                    progress_callback("Warning: Could not register script: " .. (reg_error or "unknown error"))
                end
            end
        end
        
        table.insert(results.success, url_path)
        
        ::continue::
    end
    
    return results
end

local function InstallFile(file_info, progress_callback)
    local url_path = file_info.url_path
    local target_path = ResolveInstallTarget(file_info)
    local script_type = file_info.script_type
    local repo_key = file_info.repo
    
    -- Get repository base URL (defaults to first repo if not specified)
    if not repo_key then
        repo_key = next(REPOSITORIES) -- Get first key
    end
    
    local repo_base = GetRepoRawBase(repo_key)
    
    -- Build full URL with proper encoding
    local encoded_path = URLEncode(url_path)
    local full_url = repo_base .. "/" .. encoded_path
    
    -- Build paths
    local resource_path = GetResourcePath()
    local sep = GetPathSeparator()
    
    -- Get filename
    local filename = BasenameOf(target_path)
    
    -- Special handling for Vertical FX List script
    local is_vertical_fx_list = IsVerticalFXListMain(file_info)
    local download_path
    local final_download_path
    
    if is_vertical_fx_list then
        -- Download directly to CoolReaperScripts/Vertical FX List folder with different name
        local bryan_scripts_folder = resource_path .. sep .. "Scripts" .. sep .. "CoolReaperScripts" .. sep .. "Vertical FX List"
        EnsureDirectoryExists(bryan_scripts_folder)
        final_download_path = bryan_scripts_folder .. sep .. "CRS_vertical fx list.lua"
        download_path = final_download_path -- Use same path for download
    else
        -- Download to DOWNLOAD folder first (normal behavior)
        local download_folder = resource_path .. sep .. "Scripts" .. sep .. "CoolReaperScripts" .. sep .. "Vertical FX List" .. sep .. "DOWNLOAD"
        EnsureDirectoryExists(download_folder)
        download_path = download_folder .. sep .. filename
        final_download_path = download_path
    end
    
    -- Download file
    if progress_callback then
        progress_callback("Downloading: " .. url_path)
    end
    
    local success, error_msg = DownloadFileToDisk(full_url, download_path)
    
    if not success then
        return false, "Download error: " .. (error_msg or "unknown error") .. " (URL: " .. full_url .. ")"
    end
    
    if progress_callback then
        if is_vertical_fx_list then
            progress_callback("Downloaded to CoolReaperScripts/Vertical FX List folder as CRS_vertical fx list.lua")
        else
            progress_callback("Downloaded to DOWNLOAD folder")
        end
    end
    
    -- Build final target path
    local full_target = resource_path .. sep .. NormalizePath(target_path)
    
    -- For Vertical FX List, skip copying (already in final location with different name)
    -- For other files, copy from DOWNLOAD folder to final location
    if not is_vertical_fx_list then
        -- Check if file already exists - skip if it does (don't overwrite)
        local existing_file = io.open(full_target, "rb")
        if existing_file then
            existing_file:close()
            if progress_callback then
                progress_callback("Skipping (file already exists): " .. target_path)
            end
            return true, nil -- Success (skipped)
        end
        
        -- Copy from DOWNLOAD folder to final location
        if progress_callback then
            progress_callback("Installing: " .. target_path)
        end
        
        local copy_success, copy_error = CopyFile(download_path, full_target)
        if not copy_success then
            return false, "Failed to copy file: " .. (copy_error or "unknown error")
        end
    end
    
    -- Register script if applicable
    script_type = script_type or DetectScriptType(target_path)
    if script_type == "lua" or script_type == "eel" or script_type == "py" then
        if progress_callback then
            if is_vertical_fx_list then
                progress_callback("Registering CRS_vertical fx list.lua from CoolReaperScripts/Vertical FX List folder")
            else
                progress_callback("Registering: " .. target_path)
            end
        end
        
        -- For Vertical FX List, register from CoolReaperScripts/Vertical FX List folder with CRS_ name
        -- For other scripts, register from final location
        local script_path_to_register = is_vertical_fx_list and final_download_path or full_target
        
        local reg_success, reg_error = RegisterScript(script_path_to_register, script_type)
        if not reg_success then
            -- Non-fatal: file is installed, just not registered
            if progress_callback then
                progress_callback("Warning: Could not register script: " .. (reg_error or "unknown error"))
            end
        end
    end
    
    return true, nil
end

-- ============================================================================
-- MAIN INSTALLATION FUNCTION (Non-blocking with defer)
-- ============================================================================

-- Installation state (persists across defer calls)
local install_state = {
    files = {},
    current_index = 0,
    results = {success = {}, failed = {}},
    total = 0,
    started = false,
    use_release = false, -- Whether installing from release
    release_zip_extracted = nil, -- Path to extracted release folder
}

local FinishInstallation

local function GetSelectedRepoKeys()
    local keys = {}
    for _, repo_key in ipairs(commit_gui_state.repos_to_select) do
        if commit_gui_state.selected_repos[repo_key] ~= false then
            keys[#keys + 1] = repo_key
        end
    end
    return keys
end

local function BuildPostInstallMessage(success_count, failed_count, repo_keys)
    local lines = {
        "Installation complete!",
        "",
        string.format("Installed %d file(s).", success_count or 0),
    }
    if (failed_count or 0) > 0 then
        lines[#lines + 1] = string.format("%d file(s) failed — see the log for details.", failed_count)
    end

    local names = {}
    local actions = {}
    for _, repo_key in ipairs(repo_keys or {}) do
        local repo = REPOSITORIES[repo_key]
        if repo then
            names[#names + 1] = "  • " .. (repo.display or repo.repo)
            for _, action in ipairs(repo.action_names or {}) do
                actions[#actions + 1] = "  • " .. action
            end
        end
    end
    if #names > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Scripts:"
        for _, name in ipairs(names) do
            lines[#lines + 1] = name
        end
    end
    local installed_stem_split = false
    if #actions > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "To start:"
        lines[#lines + 1] = "1. Actions → Show Action List"
        lines[#lines + 1] = "2. Search for:"
        for _, action in ipairs(actions) do
            lines[#lines + 1] = action
        end
        lines[#lines + 1] = "3. Run it from the list"
    end
    for _, repo_key in ipairs(repo_keys or {}) do
        if repo_key == "stem_split" then
            installed_stem_split = true
            break
        end
    end
    if installed_stem_split then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Split to Stems is Apple Silicon only. First run downloads model weights."
    end
    return table.concat(lines, "\n")
end

local function ShowInstallSummary()
    local results = install_state.results
    
    -- Update GUI to show completion
    if commit_gui_state.ctx then
        commit_gui_state.install_progress = 1.0
        commit_gui_state.install_success_count = #results.success
        commit_gui_state.install_failed_count = #results.failed
        
        -- Show modal popup with installation summary
        if #results.success > 0 then
            local repo_keys = install_state.installed_repos or GetSelectedRepoKeys()
            commit_gui_state.modal_title = "Installation Complete"
            commit_gui_state.modal_message = BuildPostInstallMessage(
                #results.success,
                #results.failed,
                repo_keys
            )
            commit_gui_state.modal_type = (#results.failed == 0) and "success" or "error"
            commit_gui_state.show_modal = true
        else
            -- All failed
            commit_gui_state.modal_title = "Installation Failed"
            commit_gui_state.modal_message = string.format(
                "Failed to install %d file(s).\n\nPlease check the installation logs.",
                #results.failed
            )
            commit_gui_state.modal_type = "error"
            commit_gui_state.show_modal = true
        end
        
        -- Reset installation state
        install_state = {files = {}, current_index = 0, results = {success = {}, failed = {}}, total = 0, started = false, use_release = false, release_zip_extracted = nil}
        
        -- Reset GUI installation state (but keep modal open)
        commit_gui_state.installing = false
        commit_gui_state.install_progress = 0.0
        commit_gui_state.install_current_file = ""
        commit_gui_state.install_status = ""
        commit_gui_state.install_total = 0
    end
end

-- Process one file per defer call (non-blocking)
local function ProcessNextFile()
    -- If using release, handle differently
    if install_state.use_release then
        if not install_state.release_zip_extracted then
            -- Download and extract zip first
            -- Use the repo that is actually being installed, not an arbitrary selected_releases entry
            local repo_key = install_state.installed_repos and install_state.installed_repos[1]
            if not repo_key then
                repo_key = next(REPOSITORIES)
            end
            local release_tag = commit_gui_state.selected_releases[repo_key]
            local ui = commit_gui_state.repo_ui and commit_gui_state.repo_ui[repo_key]
            local releases = (ui and ui.releases) or commit_gui_state.releases
            
            -- Find the release zip URL
            local zip_url = nil
            for _, release in ipairs(releases) do
                if release.tag == release_tag then
                    zip_url = release.zip_url
                    break
                end
            end
            
            if not zip_url then
                local err = "Release zip URL not found"
                install_state.results.failed = {{path = "release", error = err}}
                if commit_gui_state.ctx then
                    table.insert(commit_gui_state.install_log, {
                        file = "release",
                        path = "release",
                        status = "failed",
                        message = err
                    })
                    commit_gui_state.install_failed_count = #install_state.results.failed
                    commit_gui_state.install_log_expanded = true
                    commit_gui_state.install_status = "Failed: " .. err
                end
                ShowInstallSummary()
                return
            end
            
            -- Download and extract
            local extracted_folder, error_msg = DownloadAndExtractZip(zip_url, function(msg)
                if commit_gui_state.ctx then
                    commit_gui_state.install_status = msg
                end
            end)
            
            if not extracted_folder then
                local err = error_msg or "Failed to extract release"
                install_state.results.failed = {{path = "release", error = err}}
                if commit_gui_state.ctx then
                    table.insert(commit_gui_state.install_log, {
                        file = "release",
                        path = "release",
                        status = "failed",
                        message = err
                    })
                    commit_gui_state.install_failed_count = #install_state.results.failed
                    commit_gui_state.install_log_expanded = true
                    commit_gui_state.install_status = "Failed: " .. err
                end
                ShowInstallSummary()
                return
            end
            
            install_state.release_zip_extracted = extracted_folder
            
            -- Update progress
            if commit_gui_state.ctx then
                commit_gui_state.install_progress = 0.3 -- 30% for download/extract
                commit_gui_state.install_status = "Installing files from release..."
            end
            
            -- Continue to installation
            r.defer(ProcessNextFile)
            return
        else
            -- Install files from extracted folder
            local file_count = 0
            local results = InstallFromRelease(install_state.release_zip_extracted, function(msg)
                if commit_gui_state.ctx then
                    commit_gui_state.install_status = msg
                    -- Update progress based on files processed (approximate)
                    file_count = file_count + 1
                    local total = math.max(1, install_state.total or #FILES_TO_INSTALL)
                    commit_gui_state.install_progress = 0.3 + (file_count / total * 0.7) -- 30-100%
                end
            end, install_state.files)
            
            install_state.results = results
            
            -- Add to install log
            if commit_gui_state.ctx then
                local function log_name(url_path)
                    for _, file_info in ipairs(FILES_TO_INSTALL) do
                        if file_info.url_path == url_path then
                            return BasenameOf(ResolveInstallTarget(file_info))
                        end
                    end
                    local name = BasenameOf(url_path)
                    if name == "FXD_Vertical FX list.lua" then
                        return "CRS_vertical fx list.lua"
                    end
                    return name
                end
                for _, file_path in ipairs(results.success) do
                    table.insert(commit_gui_state.install_log, {
                        file = log_name(file_path),
                        path = file_path,
                        status = "success",
                        message = "Installed successfully"
                    })
                end
                for _, failed in ipairs(results.failed) do
                    table.insert(commit_gui_state.install_log, {
                        file = log_name(failed.path),
                        path = failed.path,
                        status = "failed",
                        message = failed.error or "Unknown error"
                    })
                end
                commit_gui_state.install_success_count = #results.success
                commit_gui_state.install_failed_count = #results.failed
            end
            
            -- Done
            if commit_gui_state.ctx then
                commit_gui_state.install_progress = 1.0
                commit_gui_state.install_status = "Installation complete!"
            end
            FinishInstallation()
            return
        end
    end
    
    -- Original file-by-file installation (for commits)
    if not install_state.started or install_state.current_index >= install_state.total then
        -- Update GUI progress to 100%
        if commit_gui_state.ctx then
            commit_gui_state.install_progress = 1.0
            commit_gui_state.install_status = "Installation complete!"
        end
        FinishInstallation()
        return -- Done
    end
    
    local i = install_state.current_index + 1
    install_state.current_index = i
    local file_info = install_state.files[i]
    local results = install_state.results
    
    -- Update GUI progress
    if commit_gui_state.ctx then
        commit_gui_state.install_progress = i / install_state.total
        -- Get filename from the installed (possibly CRS_ prefixed) path
        local dest_target = ResolveInstallTarget(file_info)
        commit_gui_state.install_current_file = BasenameOf(dest_target)
        commit_gui_state.install_status = "Installing..."
        commit_gui_state.install_success_count = #results.success
        commit_gui_state.install_failed_count = #results.failed
    end
    
    local repo_key = file_info.repo or next(REPOSITORIES)
    local repo = REPOSITORIES[repo_key]
    
    local success, error_msg = InstallFile(file_info, function(msg)
        -- Update GUI status with current operation
        if commit_gui_state.ctx then
            commit_gui_state.install_status = msg
        end
    end)
    
    -- Get filename from the installed (possibly CRS_ prefixed) path
    local dest_target = ResolveInstallTarget(file_info)
    local file_name = BasenameOf(dest_target)
    local target_path = dest_target
    
    if success then
        table.insert(results.success, file_info.url_path)
        if commit_gui_state.ctx then
            commit_gui_state.install_success_count = #results.success
            -- Add to install log with full path
            table.insert(commit_gui_state.install_log, {
                file = file_name,
                path = target_path,
                status = "success",
                message = "Installed successfully"
            })
        end
    else
        table.insert(results.failed, {path = file_info.url_path, error = error_msg})
        if commit_gui_state.ctx then
            commit_gui_state.install_failed_count = #results.failed
            commit_gui_state.install_status = "Failed: " .. (error_msg or "unknown error")
            -- Add to install log with full path
            table.insert(commit_gui_state.install_log, {
                file = file_name,
                path = target_path,
                status = "failed",
                message = error_msg or "Unknown error"
            })
        end
    end
    
    -- Schedule next file (allows UI to update)
    r.defer(ProcessNextFile)
end

local function InstallAllFiles()
    if #FILES_TO_INSTALL == 0 then
        r.ShowMessageBox(
            "No files configured for installation.\n\n" ..
            "Please edit the script and add files to FILES_TO_INSTALL table.",
            "No Files Configured",
            0
        )
        return
    end
    
    -- Only install files for ticked products
    local selected_keys = GetSelectedRepoKeys()
    if #selected_keys == 0 then
        if commit_gui_state.ctx then
            commit_gui_state.installing = false
            commit_gui_state.modal_title = "Nothing selected"
            commit_gui_state.modal_message = "Tick at least one script to install."
            commit_gui_state.modal_type = "error"
            commit_gui_state.show_modal = true
        end
        return
    end
    local selected_set = {}
    for _, key in ipairs(selected_keys) do
        selected_set[key] = true
    end
    local files = {}
    for _, file_info in ipairs(FILES_TO_INSTALL) do
        local repo_key = file_info.repo or "main"
        if selected_set[repo_key] then
            files[#files + 1] = file_info
        end
    end
    if #files == 0 then
        if commit_gui_state.ctx then
            commit_gui_state.installing = false
        end
        return
    end

    -- Zip install only works for a single-repo release.
    local use_release = false
    if #selected_keys == 1 then
        local current_repo_key = selected_keys[1]
        local ui = commit_gui_state.repo_ui[current_repo_key]
        if current_repo_key and commit_gui_state.selected_releases[current_repo_key]
            and ui and ui.use_releases and ui.releases then
            use_release = true
            commit_gui_state.releases = ui.releases
        end
    end
    for _, repo_key in ipairs(selected_keys) do
        SELECTED_COMMITS[repo_key] = commit_gui_state.selected_commits[repo_key]
            or commit_gui_state.selected_releases[repo_key]
            or (REPOSITORIES[repo_key] and REPOSITORIES[repo_key].branch)
    end
    
    -- Initialize installation state
    install_state.files = files
    install_state.current_index = 0
    install_state.results = {success = {}, failed = {}}
    install_state.total = #files
    install_state.started = true
    install_state.use_release = use_release
    install_state.release_zip_extracted = nil
    install_state.installed_repos = selected_keys
    install_state.stem_venv_done = false
    
    -- Initialize GUI progress state
    if commit_gui_state.ctx then
        commit_gui_state.installing = true
        commit_gui_state.install_progress = 0.0
        commit_gui_state.install_current_file = ""
        commit_gui_state.install_status = "Starting installation..."
        commit_gui_state.install_success_count = 0
        commit_gui_state.install_failed_count = 0
        commit_gui_state.install_total = install_state.total
        commit_gui_state.install_log = {} -- Clear previous log
        commit_gui_state.install_log_expanded = false -- Reset expansion state
    end
    
    -- Start processing files one at a time (non-blocking)
    r.defer(ProcessNextFile)
end

-- ============================================================================
-- COMMIT SELECTION GUI
-- ============================================================================

-- Check if ReaImGui is available
local function CheckReaImGui()
    if not r.APIExists("ImGui_GetVersion") then
        return false
    end
    return true
end

-- ============================================================================
-- PRIVATE STANDALONE PYTHON (python-build-standalone)
-- Ships a CPython next to Cool Reaper Scripts. No admin, no PATH changes.
-- ============================================================================

local PYTHON_STANDALONE = {
    latest_meta = "https://raw.githubusercontent.com/astral-sh/python-build-standalone/latest-release/latest-release.json",
    asset_prefix = "https://github.com/astral-sh/python-build-standalone/releases/download/",
    fallback_tag = "20260825",
}

local function TrimProcessOutput(s)
    if not s then return "" end
    s = tostring(s)
    if s == "-999" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function FileExistsPath(path)
    if not path or path == "" then
        return false
    end
    if r.file_exists and r.file_exists(path) then
        return true
    end
    local fh = io.open(path, "rb")
    if not fh then
        return false
    end
    fh:close()
    return true
end

local function CoolReaperScriptsDir()
    return GetResourcePath() .. GetPathSeparator() .. "Scripts" .. GetPathSeparator() .. "CoolReaperScripts"
end

local function BundledPythonDir()
    return CoolReaperScriptsDir() .. GetPathSeparator() .. "python"
end

local function GetBundledPythonBin()
    local dir = BundledPythonDir()
    local OS = r.GetOS()
    local candidates
    if OS:match("Win") then
        candidates = {
            dir .. "\\python.exe",
            dir .. "/python.exe",
        }
    else
        candidates = {
            dir .. "/bin/python3",
            dir .. "/bin/python3.13",
            dir .. "/bin/python",
        }
    end
    for _, path in ipairs(candidates) do
        if FileExistsPath(path) then
            return path
        end
    end
    return nil
end

local function DetectStandalonePythonTriple()
    local OS = r.GetOS() or ""
    if OS == "macOS-arm64" then
        return "aarch64-apple-darwin"
    elseif OS:match("OSX") then
        return "x86_64-apple-darwin"
    elseif OS:match("Win") then
        local arch = TrimProcessOutput(r.ExecProcess('cmd /c echo %PROCESSOR_ARCHITECTURE%', 3000)):upper()
        if arch:match("ARM64") then
            return "aarch64-pc-windows-msvc"
        end
        if OS == "Win32" and not arch:match("AMD64") and not arch:match("X64") then
            return nil, "64-bit REAPER is required to install the private Python."
        end
        return "x86_64-pc-windows-msvc"
    end

    -- Linux / Other
    local machine = TrimProcessOutput(r.ExecProcess("/usr/bin/uname -m", 3000)):lower()
    if machine == "aarch64" or machine == "arm64" then
        return "aarch64-unknown-linux-gnu"
    elseif machine == "x86_64" or machine == "amd64" then
        return "x86_64-unknown-linux-gnu"
    end
    return nil, "This OS/architecture is not supported for the private Python install (" .. OS .. ")."
end

local function RunCmd(cmd, timeout_ms)
    local result = r.ExecProcess(cmd, timeout_ms or 30000)
    if result == "-999" then
        return nil, "Command timed out"
    end
    return result, nil
end

local function RemoveDir(path)
    if not path or path == "" then
        return
    end
    local OS = r.GetOS()
    if OS:match("Win") then
        RunCmd(string.format('cmd /c if exist "%s" rmdir /s /q "%s"', path, path), 60000)
    else
        RunCmd(string.format('/bin/rm -rf "%s"', path), 60000)
    end
end

local function DirHasContents(path)
    if not path or path == "" then
        return false
    end
    if r.EnumerateFiles(path, 0) then
        return true
    end
    if r.EnumerateSubdirectories(path, 0) then
        return true
    end
    return false
end

local function MoveDir(src, dest)
    local OS = r.GetOS()
    local cmd
    if OS:match("Win") then
        cmd = string.format('cmd /c move /Y "%s" "%s"', src, dest)
    else
        cmd = string.format('/bin/mv "%s" "%s"', src, dest)
    end
    local result, err = RunCmd(cmd, 60000)
    if err then
        return false, err
    end
    if not DirHasContents(dest) then
        return false, "Failed to move Python folder" .. (result and (": " .. result) or "")
    end
    return true
end

local function DownloadUrlToFile(url, output_path, timeout_ms)
    local OS = r.GetOS()
    EnsureDirectoryExists(GetDirectoryFromPath(output_path))
    local escaped_path = output_path:gsub('"', '\\"')
    local cmd
    if OS:match("Win") then
        cmd = string.format('curl -L -f -s -S -A "CoolReaperScriptInstaller" -H "Accept: application/vnd.github.v3+json" -o "%s" "%s" 2>&1', escaped_path, url)
    else
        cmd = string.format('/usr/bin/curl -L -f -s -S -A "CoolReaperScriptInstaller" -H "Accept: application/vnd.github.v3+json" -o "%s" "%s" 2>&1', escaped_path, url)
    end
    local result, err = RunCmd(cmd, timeout_ms or 180000)
    if err then
        return false, err
    end
    local file = io.open(output_path, "rb")
    if not file then
        return false, "Download failed" .. (result and (": " .. result) or "")
    end
    local size = file:seek("end")
    file:close()
    if not size or size == 0 then
        return false, "Downloaded file is empty" .. (result and (": " .. result) or "")
    end
    return true, size
end

local function ReadFileContents(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local content = file:read("*all")
    file:close()
    return content
end

local function FindStandaloneAssetName(api_json, tag, triple)
    local function match_series(series)
        local esc_tag = tag:gsub("(%W)", "%%%1")
        local esc_triple = triple:gsub("(%W)", "%%%1")
        local esc_series = series:gsub("%.", "%%.")
        local pat = '"name"%s*:%s*"(cpython%-' .. esc_series .. '%.%d+%+' .. esc_tag .. '%-' .. esc_triple .. '%-install_only_stripped%.tar%.gz)"'
        return api_json:match(pat)
    end
    return match_series("3.13") or match_series("3.14") or match_series("3.12")
end

local function ClearMacQuarantine(path)
    local OS = r.GetOS()
    if not (OS:match("OSX") or OS:match("macOS")) then
        return
    end
    RunCmd(string.format('/usr/bin/xattr -dr com.apple.quarantine "%s"', path), 30000)
    RunCmd(string.format('/bin/chmod -R u+rx "%s/bin"', path), 15000)
end

local function RefreshBundledPythonStatus()
    local bin = GetBundledPythonBin()
    commit_gui_state.python_path = bin or ""
    commit_gui_state.python_version = ""
    if not bin then
        return
    end
    local cmd = string.format('"%s" -c "import sys; print(sys.version.split()[0])"', bin)
    local out = TrimProcessOutput(r.ExecProcess(cmd, 5000))
    if out ~= "" and not out:match("[Cc]an't") and not out:match("Error") then
        commit_gui_state.python_version = out:match("([%d%.]+)") or out
    end
end

local function InstallBundledPython(progress_callback)
    local function progress(msg, frac)
        if progress_callback then
            progress_callback(msg, frac)
        end
    end

    local triple, plat_err = DetectStandalonePythonTriple()
    if not triple then
        return false, plat_err
    end

    local sep = GetPathSeparator()
    local scripts_dir = CoolReaperScriptsDir()
    local dest_dir = BundledPythonDir()
    local temp_dir = scripts_dir .. sep .. "TEMP"
    EnsureDirectoryExists(scripts_dir)
    EnsureDirectoryExists(temp_dir)

    progress("Resolving latest Python 3 build...", 0.05)
    local meta_path = temp_dir .. sep .. "python-latest-release.json"
    local tag = PYTHON_STANDALONE.fallback_tag
    local meta_ok = DownloadUrlToFile(PYTHON_STANDALONE.latest_meta, meta_path, 20000)
    if meta_ok then
        local meta = ReadFileContents(meta_path)
        local parsed = meta and meta:match('"tag"%s*:%s*"([^"]+)"')
        if parsed and parsed ~= "" then
            tag = parsed
        end
    end

    progress("Finding matching Python download (" .. triple .. ")...", 0.12)
    local api_path = temp_dir .. sep .. "python-release.json"
    local api_url = "https://api.github.com/repos/astral-sh/python-build-standalone/releases/tags/" .. tag
    local api_ok, api_err = DownloadUrlToFile(api_url, api_path, 30000)
    if not api_ok then
        return false, "Could not look up Python builds: " .. (api_err or "unknown error")
    end
    local api_json = ReadFileContents(api_path)
    if not api_json then
        return false, "Could not read Python release metadata"
    end
    local asset_name = FindStandaloneAssetName(api_json, tag, triple)
    if not asset_name then
        return false, "No standalone Python 3 build found for " .. triple
    end

    local encoded_name = asset_name:gsub("%+", "%%2B")
    local tarball_url = PYTHON_STANDALONE.asset_prefix .. tag .. "/" .. encoded_name
    local tarball_path = temp_dir .. sep .. "python-standalone.tar.gz"

    progress("Downloading " .. asset_name .. " (~25 MB)...", 0.22)
    local dl_ok, dl_err = DownloadUrlToFile(tarball_url, tarball_path, 300000)
    if not dl_ok then
        return false, "Python download failed: " .. (dl_err or "unknown error")
    end

    progress("Extracting Python...", 0.70)
    local extract_dir = temp_dir .. sep .. "python-extract"
    RemoveDir(extract_dir)
    EnsureDirectoryExists(extract_dir)

    local OS = r.GetOS()
    local extract_cmd
    if OS:match("Win") then
        extract_cmd = string.format('tar -xzf "%s" -C "%s"', tarball_path, extract_dir)
    else
        extract_cmd = string.format('/usr/bin/tar -xzf "%s" -C "%s"', tarball_path, extract_dir)
    end
    local extract_out, extract_err = RunCmd(extract_cmd, 120000)
    if extract_err then
        return false, "Python extract failed: " .. extract_err
    end

    local extracted_python = extract_dir .. sep .. "python"
    local extracted_bin
    if OS:match("Win") then
        extracted_bin = extracted_python .. sep .. "python.exe"
    else
        extracted_bin = extracted_python .. sep .. "bin" .. sep .. "python3"
        if not FileExistsPath(extracted_bin) then
            extracted_bin = extracted_python .. sep .. "bin" .. sep .. "python"
        end
    end
    if not FileExistsPath(extracted_bin) then
        return false, "Extracted Python binary not found" .. (extract_out and (": " .. extract_out) or "")
    end

    progress("Installing into Cool Reaper Scripts...", 0.85)
    RemoveDir(dest_dir)
    local moved, move_err = MoveDir(extracted_python, dest_dir)
    if not moved then
        return false, move_err
    end

    progress("Clearing macOS quarantine...", 0.93)
    ClearMacQuarantine(dest_dir)

    local bin = GetBundledPythonBin()
    if not bin then
        return false, "Python was extracted but the interpreter was not found at " .. dest_dir
    end

    local verify = TrimProcessOutput(r.ExecProcess(string.format('"%s" -c "import sys; print(sys.version.split()[0])"', bin), 8000))
    if verify == "" then
        return false, "Installed Python did not run. On macOS, Gatekeeper may still be blocking it."
    end

    pcall(os.remove, tarball_path)
    pcall(os.remove, meta_path)
    pcall(os.remove, api_path)
    RemoveDir(extract_dir)

    RefreshBundledPythonStatus()
    return true, verify
end

local function StartPythonInstall()
    if commit_gui_state.installing then
        return
    end
    commit_gui_state.installing = true
    commit_gui_state.install_progress = 0.0
    commit_gui_state.install_current_file = "Python 3"
    commit_gui_state.install_status = "Starting private Python install..."
    commit_gui_state.install_success_count = 0
    commit_gui_state.install_failed_count = 0
    commit_gui_state.install_total = 1
    commit_gui_state.install_log = {}
    commit_gui_state.install_log_expanded = true

    r.defer(function()
        local ok, detail = InstallBundledPython(function(msg, frac)
            commit_gui_state.install_status = msg or ""
            commit_gui_state.install_current_file = "Python 3"
            if frac then
                commit_gui_state.install_progress = frac
            end
        end)

        if ok then
            table.insert(commit_gui_state.install_log, {
                file = "Python 3",
                path = commit_gui_state.python_path,
                status = "success",
                message = "Installed Python " .. (detail or "")
            })
            commit_gui_state.install_success_count = 1
            commit_gui_state.install_progress = 1.0
            commit_gui_state.install_status = "Python " .. (detail or "") .. " installed"
            commit_gui_state.modal_title = "Python Installed"
            commit_gui_state.modal_message = string.format(
                "Private Python %s is ready.\n\n%s\n\nOnly Cool Reaper scripts use this copy. It is not added to PATH and does not need admin rights.\n\nWAV files work as-is. Other audio formats still need ffmpeg on your system PATH.",
                detail or "3",
                commit_gui_state.python_path
            )
            commit_gui_state.modal_type = "success"
            commit_gui_state.show_modal = true
        else
            table.insert(commit_gui_state.install_log, {
                file = "Python 3",
                path = "Python 3",
                status = "failed",
                message = detail or "unknown error"
            })
            commit_gui_state.install_failed_count = 1
            commit_gui_state.install_status = "Failed: " .. (detail or "unknown error")
            commit_gui_state.modal_title = "Python Install Failed"
            commit_gui_state.modal_message = tostring(detail or "Unknown error")
            commit_gui_state.modal_type = "error"
            commit_gui_state.show_modal = true
        end

        commit_gui_state.installing = false
    end)
end

local function ShellQuote(s)
    return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function StemSplitInstallAbsDir()
    local sep = GetPathSeparator()
    local dir = GetResourcePath() .. sep .. NormalizePath(STEM_SPLIT_INSTALL_DIR)
    if dir:sub(-1) == sep then
        dir = dir:sub(1, -2)
    end
    return dir
end

local function FindPythonForStemVenv()
    local bundled = GetBundledPythonBin()
    if bundled then
        return bundled
    end
    local candidates = {
        "/opt/homebrew/bin/python3.13",
        "/usr/local/bin/python3.13",
        "/opt/homebrew/bin/python3",
        "/usr/bin/python3",
    }
    for _, path in ipairs(candidates) do
        if FileExistsPath(path) then
            return path
        end
    end
    return nil
end

local function VenvHasStemPackages(venv_py)
    if not FileExistsPath(venv_py) then
        return false
    end
    local cmd = string.format(
        "%s -c %s",
        ShellQuote(venv_py),
        ShellQuote("import demucs_mlx, mdxnet_infer, soundfile")
    )
    local out = TrimProcessOutput(r.ExecProcess(cmd, 20000))
    if not out or out == "" then
        return true
    end
    if out:match("[Ee]rror") or out:match("Traceback") or out:match("ModuleNotFound") or out:match("No module") then
        return false
    end
    return true
end

local function InstallStemSplitVenv(progress_callback)
    local function progress(msg, frac)
        if progress_callback then
            progress_callback(msg, frac)
        end
    end

    local OS = r.GetOS() or ""
    if OS ~= "macOS-arm64" then
        return true, "Skipped Python env (Apple Silicon only). Scripts are installed."
    end

    local dest = StemSplitInstallAbsDir()
    local req = dest .. "/requirements.txt"
    if not FileExistsPath(req) then
        return false, "requirements.txt not found in " .. dest
    end

    local py = FindPythonForStemVenv()
    if not py then
        return false, "No Python found. Click Install Python 3 in this window, then install Split to Stems again."
    end

    local venv = dest .. "/.venv-stems"
    local venv_py = venv .. "/bin/python"
    local pip = venv .. "/bin/pip"

    if VenvHasStemPackages(venv_py) then
        return true, "Python environment already ready"
    end

    progress("Creating Stem Split virtualenv...", 0.15)
    EnsureDirectoryExists(dest)
    local venv_out, venv_err = RunCmd(string.format("%s -m venv %s", ShellQuote(py), ShellQuote(venv)), 120000)
    if venv_err then
        return false, "Failed to create .venv-stems: " .. venv_err
    end
    if not FileExistsPath(venv_py) then
        return false, "venv created but python was not found at " .. venv_py .. (venv_out and (": " .. venv_out) or "")
    end
    ClearMacQuarantine(venv)

    progress("Upgrading pip...", 0.28)
    RunCmd(string.format("%s install --upgrade pip", ShellQuote(pip)), 180000)

    progress("Installing Demucs-MLX (several minutes on first install)...", 0.40)
    local pip_out, pip_err = RunCmd(string.format("%s install -r %s", ShellQuote(pip), ShellQuote(req)), 900000)
    if pip_err then
        return false, "pip install failed: " .. pip_err
    end
    if not VenvHasStemPackages(venv_py) then
        local tail = ""
        if pip_out and pip_out ~= "" then
            tail = "\n" .. pip_out:sub(math.max(1, #pip_out - 800))
        end
        return false, "Packages did not import after pip install." .. tail
    end
    return true, "Demucs-MLX environment ready"
end

local function InstalledStemSplit()
    for _, key in ipairs(install_state.installed_repos or {}) do
        if key == "stem_split" then
            return true
        end
    end
    return false
end

FinishInstallation = function()
    if InstalledStemSplit() and not install_state.stem_venv_done then
        install_state.stem_venv_done = true
        if commit_gui_state.ctx then
            commit_gui_state.install_status = "Setting up Stem Split Python environment..."
            commit_gui_state.install_current_file = "Stem Split environment"
            commit_gui_state.install_progress = 0.92
        end
        r.defer(function()
            local ok, detail = InstallStemSplitVenv(function(msg, frac)
                if commit_gui_state.ctx then
                    commit_gui_state.install_status = msg or ""
                    if frac then
                        commit_gui_state.install_progress = 0.85 + (frac * 0.14)
                    end
                end
            end)
            if commit_gui_state.ctx then
                table.insert(commit_gui_state.install_log, {
                    file = "Stem Split Python env",
                    path = StemSplitInstallAbsDir() .. "/.venv-stems",
                    status = ok and "success" or "failed",
                    message = detail or "",
                })
            end
            if ok then
                table.insert(install_state.results.success, ".venv-stems")
            else
                table.insert(install_state.results.failed, {path = ".venv-stems", error = detail})
            end
            ShowInstallSummary()
        end)
        return
    end
    ShowInstallSummary()
end

-- Fetch releases from GitHub API (list all releases, no filtering)
local function FetchReleases(user, repo)
    local url = string.format("https://api.github.com/repos/%s/%s/releases", user, repo)
    
    local OS = r.GetOS()
    local cmd
    if OS:match("Win") then
        cmd = string.format('curl -s -H "Accept: application/vnd.github.v3+json" "%s"', url)
    else
        cmd = string.format('/usr/bin/curl -s -H "Accept: application/vnd.github.v3+json" "%s"', url)
    end
    
    local result = r.ExecProcess(cmd, 10000)
    if not result or result == "" then
        local handle = io.popen(cmd, "r")
        if handle then
            local lines = {}
            for line in handle:lines() do
                table.insert(lines, line)
            end
            result = table.concat(lines, "\n")
            handle:close()
        end
    end
    
    if not result or result == "" then
        return nil, "Failed to fetch releases (empty response)"
    end
    
    -- Clean up response: remove any leading non-JSON characters
    local json_start = result:find("[%[%{]")
    if json_start and json_start > 1 then
        result = result:sub(json_start)
    end
    
    -- Check for API errors
    if result:match('"message"') and result:match('"documentation_url"') then
        local error_msg = result:match('"message":"([^"]+)"')
        return nil, error_msg or "GitHub API error"
    end
    
    -- Check if response starts with array bracket
    if not result:match("^%s*%[") then
        return nil, "Invalid response format (expected JSON array)"
    end
    
    -- Parse releases JSON
    local releases = {}
    local pos = 1
    
    while true do
        -- Find "tag_name" field
        local tag_start = result:find('"tag_name"', pos)
        if not tag_start then break end
        
        -- Find colon after "tag_name"
        local colon = result:find(':', tag_start)
        if not colon then break end
        
        -- Find opening quote
        local quote = colon + 1
        while quote <= #result and result:sub(quote, quote):match("%s") do
            quote = quote + 1
        end
        
        if result:sub(quote, quote) == '"' then
            local tag_end = result:find('"', quote + 1)
            if tag_end then
                local tag = result:sub(quote + 1, tag_end - 1)
                
                -- Find "zipball_url" for this release
                local zipball_start = result:find('"zipball_url"', tag_start)
                if zipball_start then
                    local zip_colon = result:find(':', zipball_start)
                    if zip_colon then
                        local zip_quote = zip_colon + 1
                        while zip_quote <= #result and result:sub(zip_quote, zip_quote):match("%s") do
                            zip_quote = zip_quote + 1
                        end
                        if result:sub(zip_quote, zip_quote) == '"' then
                            local zip_quote_end = result:find('"', zip_quote + 1)
                            if zip_quote_end then
                                local zip_url = result:sub(zip_quote + 1, zip_quote_end - 1)
                                
                                -- Extract version from tag (remove 'v' prefix if present)
                                local version = tag:match("^v?(.+)$") or tag
                                
                                table.insert(releases, {
                                    tag = tag,
                                    version = version,
                                    zip_url = zip_url
                                })
                            end
                        end
                    end
                end
            end
        end
        
        pos = tag_start + 10
    end
    
    if #releases == 0 then
        return nil, "No releases found"
    end
    
    return releases, nil
end

-- Fetch releases from GitHub API
local function FetchReleases(user, repo)
    local url = string.format("https://api.github.com/repos/%s/%s/releases", user, repo)
    
    local OS = r.GetOS()
    local cmd
    if OS:match("Win") then
        cmd = string.format('curl -s -H "Accept: application/vnd.github.v3+json" "%s"', url)
    else
        cmd = string.format('/usr/bin/curl -s -H "Accept: application/vnd.github.v3+json" "%s"', url)
    end
    
    local result = r.ExecProcess(cmd, 10000)
    if not result or result == "" then
        local handle = io.popen(cmd, "r")
        if handle then
            local lines = {}
            for line in handle:lines() do
                table.insert(lines, line)
            end
            result = table.concat(lines, "\n")
            handle:close()
        end
    end
    
    if not result or result == "" then
        return nil, "Failed to fetch releases (empty response)"
    end
    
    -- Clean up response: remove any leading non-JSON characters
    local json_start = result:find("[%[%{]")
    if json_start and json_start > 1 then
        result = result:sub(json_start)
    end
    
    -- Check for API errors
    if result:match('"message"') and result:match('"documentation_url"') then
        local error_msg = result:match('"message":"([^"]+)"')
        return nil, error_msg or "GitHub API error"
    end
    
    -- Check if response starts with array bracket
    if not result:match("^%s*%[") then
        return nil, "Invalid response format (expected JSON array)"
    end
    
    -- Parse releases JSON
    local releases = {}
    local pos = 1
    
    while true do
        -- Find "tag_name" field
        local tag_start = result:find('"tag_name"', pos)
        if not tag_start then break end
        
        -- Find colon after "tag_name"
        local colon = result:find(':', tag_start)
        if not colon then break end
        
        -- Find opening quote
        local quote = colon + 1
        while quote <= #result and result:sub(quote, quote):match("%s") do
            quote = quote + 1
        end
        
        if result:sub(quote, quote) ~= '"' then break end
        
        -- Find closing quote
        local tag_end = result:find('"', quote + 1)
        if not tag_end then break end
        
        local tag = result:sub(quote + 1, tag_end - 1)
        
        -- Find zipball_url for this release
        local zipball_start = result:find('"zipball_url"', tag_start)
        local zip_url = nil
        if zipball_start then
            local zip_colon = result:find(':', zipball_start)
            if zip_colon then
                local zip_quote = zip_colon + 1
                while zip_quote <= #result and result:sub(zip_quote, zip_quote):match("%s") do
                    zip_quote = zip_quote + 1
                end
                if result:sub(zip_quote, zip_quote) == '"' then
                    local zip_quote_end = result:find('"', zip_quote + 1)
                    if zip_quote_end then
                        zip_url = result:sub(zip_quote + 1, zip_quote_end - 1)
                    end
                end
            end
        end
        
        if zip_url then
            -- Extract version from tag (remove 'v' prefix if present)
            local version = tag:match("^v?(.+)$") or tag
            table.insert(releases, {
                tag = tag,
                version = version,
                zip_url = zip_url
            })
        end
        
        pos = tag_start + 10
    end
    
    if #releases == 0 then
        return nil, "No releases found"
    end
    
    return releases, nil
end

-- Fetch commits from GitHub API
local function FetchCommits(user, repo, branch)
    local url = string.format("https://api.github.com/repos/%s/%s/commits?sha=%s&per_page=50", user, repo, branch)
    
    local OS = r.GetOS()
    local cmd
    if OS:match("Win") then
        cmd = string.format('curl -s -H "Accept: application/vnd.github.v3+json" "%s"', url)
    else
        cmd = string.format('/usr/bin/curl -s -H "Accept: application/vnd.github.v3+json" "%s"', url)
    end
    
    local result = r.ExecProcess(cmd, 10000)
    if not result or result == "" then
        local handle = io.popen(cmd, "r")
        if handle then
            local lines = {}
            for line in handle:lines() do
                table.insert(lines, line)
            end
            result = table.concat(lines, "\n")
            handle:close()
        end
    end
    
    if not result or result == "" then
        return nil, "Failed to fetch commits (empty response)"
    end
    
    -- Clean up response: remove any leading non-JSON characters (like curl exit codes, newlines, etc.)
    -- Find the first '[' or '{' which should be the start of JSON
    local json_start = result:find("[%[%{]")
    if json_start and json_start > 1 then
        result = result:sub(json_start)
    end
    
    -- Check for API errors
    if result:match('"message"') and result:match('"documentation_url"') then
        local error_msg = result:match('"message":"([^"]+)"')
        return nil, error_msg or "GitHub API error"
    end
    
    -- Check if response starts with array bracket
    if not result:match("^%s*%[") then
        return nil, "Invalid response format (expected JSON array, got: " .. result:sub(1, 50) .. "...)"
    end
    
    -- Parse JSON (simple parser for GitHub API format)
    -- Structure: [{"sha":"...","commit":{"message":"...","author":{"name":"...","date":"..."}}}, ...]
    local commits = {}
    local seen_shas = {} -- Track SHAs we've already processed to avoid duplicates
    local commits_by_sha = {} -- Track commits by SHA for fast duplicate checking
    
    -- Find all SHA values in original result (handle whitespace in JSON)
    -- Only look for top-level "sha" fields (not nested ones inside commit objects)
    local sha_data = {} -- Store {sha_value_start, label_start, sha_string} for each commit
    local pos = 1
    
    while true do
        -- Look for "sha" field at top level of commit object
        -- Pattern: "sha" that appears right after '{' (start of commit object in array)
        -- We want to match: [ { "sha": "..." } ] but NOT [ { "commit": { "tree": { "sha": "..." } } } ]
        local sha_label_start = result:find('"sha"', pos)
        if not sha_label_start then break end
        
        -- Check if this is a top-level sha in a commit object
        -- Look backwards to find the opening brace of the commit object
        local check_pos = sha_label_start - 1
        local found_opening_brace = false
        local brace_pos = nil
        
        -- Look backwards up to 200 chars to find the opening brace
        while check_pos >= math.max(1, sha_label_start - 200) do
            local char = result:sub(check_pos, check_pos)
            if char == '{' then
                found_opening_brace = true
                brace_pos = check_pos
                break
            elseif char == '}' or char == ']' then
                -- Hit a closing brace/bracket, this isn't a top-level sha
                break
            end
            check_pos = check_pos - 1
        end
        
        -- Only process if we found an opening brace
        if found_opening_brace and brace_pos then
            -- Check the text between the opening brace and "sha"
            local between = result:sub(brace_pos + 1, sha_label_start - 1)
            
            -- Check if there's a nested '{' between this brace and the "sha"
            -- If there is, this is a nested sha (like in "tree": { "sha": ... })
            local has_nested_brace = between:find('{')
            
            -- Check if this is a direct child (either first field or after a comma)
            -- Pattern: only whitespace/newlines then "sha" OR comma, whitespace, then "sha"
            -- Normalize whitespace for matching (whitespace-only means it's the first field)
            local normalized_between = between:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
            local is_direct_child = normalized_between == "" or normalized_between:match('^"sha"') or normalized_between:match(',%s*"sha"')
            
            
            -- Only process if it's a direct child AND no nested braces (top-level sha)
            if is_direct_child and not has_nested_brace then
                -- Find colon after "sha" (skip whitespace)
                local colon_pos = result:find(':', sha_label_start)
                if colon_pos then
                    -- Find opening quote after colon (skip whitespace)
                    local quote_pos = colon_pos + 1
                    while quote_pos <= #result and result:sub(quote_pos, quote_pos):match("%s") do
                        quote_pos = quote_pos + 1
                    end
                    
                    if result:sub(quote_pos, quote_pos) == '"' then
                        -- SHA value starts right after the quote
                        local sha_value_start = quote_pos + 1
                        local sha_end = result:find('"', sha_value_start)
                        if sha_end then
                            local sha_string = result:sub(sha_value_start, sha_end - 1)
                            -- Only add if we haven't seen this SHA before
                            if not seen_shas[sha_string] and sha_string:match("^[0-9a-fA-F]+$") and #sha_string >= 7 then
                                seen_shas[sha_string] = true
                                table.insert(sha_data, {sha_start = sha_value_start, label_start = sha_label_start, sha_string = sha_string})
                            end
                        end
                    end
                end
            end
        end
        
        -- Move to next position
        pos = sha_label_start + 5
    end
    
    -- Process each commit
    for i, sha_info in ipairs(sha_data) do
        local sha = sha_info.sha_string -- Use the SHA we already extracted
        
        -- Find commit object for this SHA (search within next 3000 chars to be safe)
        local search_start = sha_info.label_start
        local search_end = math.min(search_start + 3000, #result)
        
        -- Find "commit" label after this SHA (should be nearby)
        local commit_label_pos = result:find('"commit"', search_start, search_end)
        if not commit_label_pos then
            goto continue
        end
        
        -- Find the opening brace of commit object (should be right after "commit":)
        -- Look for colon first, then brace
        local colon_after_commit = result:find(':', commit_label_pos)
        if not colon_after_commit then
            goto continue
        end
        
        -- Skip whitespace after colon
        local brace_pos = colon_after_commit + 1
        while brace_pos <= #result and result:sub(brace_pos, brace_pos):match("%s") do
            brace_pos = brace_pos + 1
        end
        
        if result:sub(brace_pos, brace_pos) ~= '{' then
            goto continue
        end
        
        local commit_brace_pos = brace_pos
        
        -- Extract message (look for "message":" within commit object, search up to 1500 chars)
        local message = ""
        local msg_search_end = math.min(commit_brace_pos + 1500, #result)
        local msg_pattern_start = result:find('"message"', commit_brace_pos, msg_search_end)
        if msg_pattern_start then
            -- Find colon after "message"
            local msg_colon = result:find(':', msg_pattern_start)
            if msg_colon then
                -- Find opening quote
                local quote_pos = msg_colon + 1
                while quote_pos <= #result and result:sub(quote_pos, quote_pos):match("%s") do
                    quote_pos = quote_pos + 1
                end
                if result:sub(quote_pos, quote_pos) == '"' then
                    local msg_text_start = quote_pos + 1
                    -- Find end of message (look for unescaped quote)
                    local msg_end = msg_text_start
                    local found_end = false
                    while msg_end <= msg_text_start + 500 and msg_end <= #result do
                        local char = result:sub(msg_end, msg_end)
                        if char == '"' then
                            -- Check if escaped by counting backslashes
                            local backslash_count = 0
                            local check = msg_end - 1
                            while check >= msg_text_start and result:sub(check, check) == "\\" do
                                backslash_count = backslash_count + 1
                                check = check - 1
                            end
                            -- If even number of backslashes (or zero), quote is not escaped
                            if backslash_count % 2 == 0 then
                                message = result:sub(msg_text_start, msg_end - 1)
                                found_end = true
                                break
                            end
                        end
                        msg_end = msg_end + 1
                    end
                    if found_end then
                        message = message:gsub("\\n", " "):gsub("\\r", ""):gsub('\\"', '"'):gsub("\\\\", "\\")
                    end
                end
            end
        end
        
        -- Extract author name (look for "author":{ within commit object)
        local author_name = ""
        local author_search_end = math.min(commit_brace_pos + 2000, #result)
        local author_pattern_start = result:find('"author"', commit_brace_pos, author_search_end)
        if author_pattern_start then
            -- Find colon and brace after "author"
            local author_colon = result:find(':', author_pattern_start)
            if author_colon then
                local author_brace_pos = author_colon + 1
                while author_brace_pos <= #result and result:sub(author_brace_pos, author_brace_pos):match("%s") do
                    author_brace_pos = author_brace_pos + 1
                end
                if result:sub(author_brace_pos, author_brace_pos) == '{' then
                    -- Find "name":" within author block
                    local name_search_end = math.min(author_brace_pos + 300, #result)
                    local name_pattern_start = result:find('"name"', author_brace_pos, name_search_end)
                    if name_pattern_start then
                        local name_colon = result:find(':', name_pattern_start)
                        if name_colon then
                            local name_quote = name_colon + 1
                            while name_quote <= #result and result:sub(name_quote, name_quote):match("%s") do
                                name_quote = name_quote + 1
                            end
                            if result:sub(name_quote, name_quote) == '"' then
                                local name_text_start = name_quote + 1
                                local name_end = result:find('"', name_text_start)
                                if name_end then
                                    author_name = result:sub(name_text_start, name_end - 1)
                                end
                            end
                        end
                    end
                end
            end
        end
        
        -- Extract date (look for "date":" within author block)
        local date = ""
        if author_pattern_start then
            local author_colon = result:find(':', author_pattern_start)
            if author_colon then
                local author_brace_pos = author_colon + 1
                while author_brace_pos <= #result and result:sub(author_brace_pos, author_brace_pos):match("%s") do
                    author_brace_pos = author_brace_pos + 1
                end
                if result:sub(author_brace_pos, author_brace_pos) == '{' then
                    local date_search_end = math.min(author_brace_pos + 400, #result)
                    local date_pattern_start = result:find('"date"', author_brace_pos, date_search_end)
                    if date_pattern_start then
                        local date_colon = result:find(':', date_pattern_start)
                        if date_colon then
                            local date_quote = date_colon + 1
                            while date_quote <= #result and result:sub(date_quote, date_quote):match("%s") do
                                date_quote = date_quote + 1
                            end
                            if result:sub(date_quote, date_quote) == '"' then
                                local date_text_start = date_quote + 1
                                local date_end = result:find('"', date_text_start)
                                if date_end then
                                    local date_str = result:sub(date_text_start, date_end - 1)
                                    -- Extract date part (before 'T' if present)
                                    date = date_str:match("^([^T]+)") or date_str:sub(1, 10)
                                end
                            end
                        end
                    end
                end
            end
        end
        
        -- Simple check: don't add if we already have this SHA
        if not commits_by_sha[sha] then
            local commit_entry = {
                sha = sha,
                message = (message ~= "" and message:sub(1, 60)) or "No message",
                date = date ~= "" and date or "Unknown date",
                author = author_name ~= "" and author_name or "Unknown",
                full_sha = sha
            }
            table.insert(commits, commit_entry)
            commits_by_sha[sha] = true -- Mark as seen
        end
        
        ::continue::
    end
    
    if #commits == 0 then
        return nil, "No commits found or invalid response"
    end
    
    return commits, nil
end

-- Apply custom styling theme
local function ApplyCustomTheme(ctx)
    -- Color definitions
    local accent_color = 0x2D4F47FF  -- Dark teal/green accent
    local bg_dark = 0x1A1A1AFF       -- Very dark gray background (darker)
    local bg_medium = 0x252525FF     -- Medium gray (darker)
    local bg_light = 0x303030FF      -- Light gray (darker)
    local text_primary = 0xE0E0E0FF  -- Light gray text
    local text_secondary = 0xB0B0B0FF -- Medium gray text
    local border_color = 0x0F0F0FFF   -- Dark border (darker)
    local title_bg = 0x404040FF      -- Gray title bar
    local title_bg_active = 0x505050FF -- Active title bar (slightly lighter)
    
    -- Window colors (only use supported constants)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_WindowBg(), bg_dark)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ChildBg(), bg_medium)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TitleBg(), title_bg)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TitleBgActive(), title_bg_active)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TitleBgCollapsed(), title_bg)
    
    -- Frame colors
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), bg_medium)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgHovered(), bg_light)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgActive(), bg_light)
    
    -- Button colors
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), bg_medium)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), accent_color)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x255A4FFF) -- Slightly darker accent
    
    -- Text colors
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), text_primary)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TextDisabled(), text_secondary)
    
    -- Border colors
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Border(), border_color)
    
    -- Header/Selectable colors (for dropdown items)
    -- Transparent hover color
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Header(), 0x00000000) -- Transparent
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), 0x00000000) -- Transparent
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), 0x00000000) -- Transparent
    
    -- Style variables for spacing and rounding
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowPadding(), 12.0, 12.0)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), 8.0, 6.0)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), 8.0, 6.0)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemInnerSpacing(), 6.0, 4.0)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_IndentSpacing(), 20.0)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ScrollbarSize(), 14.0)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_GrabMinSize(), 10.0)
    
    -- Rounding
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowRounding(), 6.0)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ChildRounding(), 4.0)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), 4.0)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_PopupRounding(), 4.0)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ScrollbarRounding(), 4.0)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_GrabRounding(), 4.0)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_TabRounding(), 4.0)
    
    -- Border width
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowBorderSize(), 1.0)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ChildBorderSize(), 1.0)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_PopupBorderSize(), 1.0)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameBorderSize(), 0.0)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_TabBorderSize(), 1.0)
end

-- Pop custom styling theme
local function PopCustomTheme(ctx)
    -- Pop all style colors (17 colors - 9 original + 3 title bar + 3 header + 2 frame colors)
    -- Use PopStyleColor with count parameter for safety
    r.ImGui_PopStyleColor(ctx, 17)
    -- Pop all style vars (19 vars)
    r.ImGui_PopStyleVar(ctx, 19)
end

local function LicenseExpiryUnix(expiresAt)
    local value = tonumber(expiresAt)
    if not value or value <= 0 then return nil end
    if value > 1e11 then
        value = math.floor(value / 1000)
    end
    return value
end

local function FormatLicenseDate(expiresAt)
    local value = LicenseExpiryUnix(expiresAt)
    if not value then return nil end
    return os.date("%Y-%m-%d", value)
end

local function TrialDaysLeft(expiresAt)
    local value = LicenseExpiryUnix(expiresAt)
    if not value then return nil end
    return math.floor((value - os.time()) / 86400)
end

local function BuildLicenseChip(status, expiresAt, licenseKey, reason)
    local key = licenseKey or ""
    status = status or ""

    if key == "BYPASS" then
        return {
            label = "Bypass",
            bg = 0x2A3A4AFF,
            fg = 0x8EC8FFFF,
            tooltip = "License verification is bypassed on this machine.",
            status = "bypass",
        }
    end

    if status == "active" then
        local expiry = LicenseExpiryUnix(expiresAt)
        if not expiry then
            return {
                label = "Lifetime",
                bg = 0x2D4F47FF,
                fg = 0xE8F6EFFF,
                tooltip = "You own a lifetime license for this script.",
                status = "active",
            }
        end
        local date_str = FormatLicenseDate(expiresAt) or ""
        return {
            label = "Licensed",
            bg = 0x2D4F47FF,
            fg = 0xE8F6EFFF,
            tooltip = "Licensed until " .. date_str,
            status = "active",
        }
    end

    if status == "trial" then
        local days = TrialDaysLeft(expiresAt)
        local date_str = FormatLicenseDate(expiresAt)
        if days and days < 0 then
            return {
                label = "Trial ended",
                bg = 0x4A2A2AFF,
                fg = 0xFF8A8AFF,
                tooltip = date_str and ("Trial ended on " .. date_str) or "Trial has expired.",
                status = "expired",
            }
        end
        local label
        if days == nil then
            label = "Trial"
        elseif days <= 0 then
            label = "Last day"
        elseif days == 1 then
            label = "1 day left"
        else
            label = tostring(days) .. " days left"
        end
        return {
            label = label,
            bg = 0x5C4A1FFF,
            fg = 0xFFD978FF,
            tooltip = date_str and ("Trial ends on " .. date_str) or "Trial license",
            status = "trial",
        }
    end

    if status == "expired" then
        local date_str = FormatLicenseDate(expiresAt)
        return {
            label = "Trial ended",
            bg = 0x4A2A2AFF,
            fg = 0xFF8A8AFF,
            tooltip = date_str and ("Trial ended on " .. date_str) or "Trial has expired.",
            status = "expired",
        }
    end

    return {
        label = "No license",
        bg = 0x2A2A2AFF,
        fg = 0x9A9A9AFF,
        tooltip = reason and reason ~= "" and reason or "Not activated on this machine.",
        status = "inactive",
    }
end

local function LoadLicenseFromExtState(section)
    if not section or section == "" then
        return nil
    end
    local status = r.GetExtState(section, "status") or ""
    local expiresAt = r.GetExtState(section, "expiresAt") or ""
    local licenseKey = r.GetExtState(section, "licenseKey") or ""
    local reason = r.GetExtState(section, "reason") or ""
    local deviceId = r.GetExtState(section, "deviceId") or ""
    return {
        status = status,
        expiresAt = expiresAt,
        licenseKey = licenseKey,
        reason = reason,
        deviceId = deviceId,
    }
end

local function VerifyLicenseWithServer(licenseKey, deviceId)
    if not licenseKey or licenseKey == "" or licenseKey == "BYPASS" then
        return nil
    end
    local function escape_json(str)
        if not str then return "" end
        return tostring(str):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r")
    end
    local payload = string.format('{"licenseKey":"%s","deviceId":"%s"}',
        escape_json(licenseKey), escape_json(deviceId or ""))
    local OS = r.GetOS()
    local cmd
    if OS:match("Win") then
        cmd = string.format(
            'curl -L -s -X POST -H "Content-Type: application/json" -d "%s" "%s"',
            payload:gsub('"', '\\"'),
            LICENSE_VERIFY_URL
        )
    else
        local quoted_payload = "'" .. payload:gsub("'", "'\\''") .. "'"
        local quoted_url = "'" .. LICENSE_VERIFY_URL .. "'"
        cmd = string.format(
            "/usr/bin/curl -L -s -S -X POST -H 'Content-Type: application/json' -d %s %s",
            quoted_payload,
            quoted_url
        )
    end
    local response = r.ExecProcess(cmd, 8000)
    if (not response or response == "") and io.popen then
        local handle = io.popen(cmd, "r")
        if handle then
            response = handle:read("*a") or ""
            handle:close()
        end
    end
    if not response or response == "" then
        return nil
    end
    response = response:match("^%s*(.-)%s*$") or response
    local ok = response:match('"ok"%s*:%s*true') or response:match('"success"%s*:%s*true')
    local status = response:match('"status"%s*:%s*"([^"]+)"')
    local expiresAt = nil
    local expiresAtStr = response:match('"expiresAt"%s*:%s*([^,}]+)')
    if expiresAtStr then
        expiresAtStr = expiresAtStr:match("^%s*(.-)%s*$")
        if expiresAtStr ~= "null" and expiresAtStr ~= "nil" then
            expiresAt = tonumber(expiresAtStr)
        end
    end
    local reason = response:match('"reason"%s*:%s*"([^"]+)"')
        or response:match('"message"%s*:%s*"([^"]+)"')
    if not status or status == "" then
        if ok then
            status = "active"
        else
            return nil
        end
    end
    return {
        status = status,
        expiresAt = expiresAt,
        reason = reason,
        licenseKey = licenseKey,
    }
end

local function RefreshRepoLicenseChip(repo_key)
    local repo = REPOSITORIES[repo_key]
    if not repo or not repo.license_section then return end
    local stored = LoadLicenseFromExtState(repo.license_section)
    local status = stored and stored.status or ""
    local expiresAt = stored and stored.expiresAt or ""
    local licenseKey = stored and stored.licenseKey or ""
    local reason = stored and stored.reason or ""
    if stored and stored.licenseKey and stored.licenseKey ~= "" and stored.licenseKey ~= "BYPASS" then
        local live = VerifyLicenseWithServer(stored.licenseKey, stored.deviceId)
        if live then
            status = live.status or status
            expiresAt = live.expiresAt or expiresAt
            reason = live.reason or reason
            licenseKey = live.licenseKey or licenseKey
        end
    end
    commit_gui_state.license_ui[repo_key] = BuildLicenseChip(status, expiresAt, licenseKey, reason)
end

local function DrawLicenseChip(ctx, id, chip)
    if not chip then return end
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), 11)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), 8.0, 3.0)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), chip.bg)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), chip.bg)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), chip.bg)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), chip.fg)
    r.ImGui_Button(ctx, chip.label .. "##licchip_" .. id)
    if chip.tooltip and r.ImGui_IsItemHovered(ctx) and r.ImGui_SetTooltip then
        r.ImGui_SetTooltip(ctx, chip.tooltip)
    end
    r.ImGui_PopStyleColor(ctx, 4)
    r.ImGui_PopStyleVar(ctx, 2)
end

-- Initialize commit selection GUI
local function InitCommitGUI()
    if not CheckReaImGui() then
        -- Fallback: use default branch if ReaImGui not available
        r.ShowMessageBox(
            "ReaImGui is not available. Using default branch for all repositories.\n\n" ..
            "To enable commit selection, install ReaImGui via ReaPack.",
            "ReaImGui Not Available",
            0
        )
        return false
    end
    
    -- Get list of repositories that need commit selection
    local repos_seen = {}
    for _, file_info in ipairs(FILES_TO_INSTALL) do
        local repo_key = file_info.repo or next(REPOSITORIES)
        if not repos_seen[repo_key] then
            repos_seen[repo_key] = true
            table.insert(commit_gui_state.repos_to_select, repo_key)
        end
    end
    commit_gui_state.selected_repos = commit_gui_state.selected_repos or {}
    commit_gui_state.license_ui = commit_gui_state.license_ui or {}
    for _, repo_key in ipairs(commit_gui_state.repos_to_select) do
        if commit_gui_state.selected_repos[repo_key] == nil then
            commit_gui_state.selected_repos[repo_key] = true
        end
        local key = repo_key
        local repo = REPOSITORIES[key]
        if repo and repo.license_section then
            local stored = LoadLicenseFromExtState(repo.license_section)
            commit_gui_state.license_ui[key] = BuildLicenseChip(
                stored and stored.status or "",
                stored and stored.expiresAt or "",
                stored and stored.licenseKey or "",
                stored and stored.reason or ""
            )
            r.defer(function()
                RefreshRepoLicenseChip(key)
            end)
        end
    end
    
    -- Create ImGui context
    commit_gui_state.ctx = r.ImGui_CreateContext("Cool Reaper Script Installer - Commit Selection")
    RefreshBundledPythonStatus()
    
    -- Create bold font for title (size 28)
    -- Use a bold font name since ImGui_CreateFont only accepts 2 arguments
    -- Try "Arial Black" first, fallback to "Impact" or regular "Arial"
    commit_gui_state.title_font = r.ImGui_CreateFont("Arial Black", 28)
    if not commit_gui_state.title_font then
        -- Fallback to Impact if Arial Black not available
        commit_gui_state.title_font = r.ImGui_CreateFont("Impact", 28)
    end
    if not commit_gui_state.title_font then
        -- Final fallback to regular Arial
        commit_gui_state.title_font = r.ImGui_CreateFont("Arial", 28)
    end
    if commit_gui_state.title_font and commit_gui_state.ctx then
        r.ImGui_Attach(commit_gui_state.ctx, commit_gui_state.title_font)
    end
    
    -- Load releases/commits for every repo (Sample Map has no GitHub releases yet)
    commit_gui_state.repo_ui = {}
    for _, repo_key in ipairs(commit_gui_state.repos_to_select) do
        local key = repo_key
        local repo = REPOSITORIES[key]
        if repo then
            commit_gui_state.repo_ui[key] = {
                loading = true,
                error_msg = nil,
                use_releases = false,
                releases = {},
                commits = {},
            }
            r.defer(function()
                local ui = commit_gui_state.repo_ui[key]
                if not ui then return end
                local releases = FetchReleases(repo.user, repo.repo)
                if releases and #releases > 0 then
                    ui.releases = releases
                    ui.use_releases = true
                    ui.loading = false
                    commit_gui_state.selected_releases[key] = releases[1].tag
                else
                    ui.use_releases = false
                    local commits, error_msg = FetchCommits(repo.user, repo.repo, repo.branch)
                    local versioned_commits = {}
                    if commits then
                        for _, commit in ipairs(commits) do
                            local version = ExtractVersionFromMessage(commit.message)
                            if version then
                                commit.version = version
                                table.insert(versioned_commits, commit)
                            end
                        end
                    end
                    if #versioned_commits == 0 then
                        versioned_commits[1] = {
                            sha = repo.branch,
                            version = repo.branch,
                            message = "Latest (" .. repo.branch .. ")",
                        }
                    end
                    ui.commits = versioned_commits
                    ui.loading = false
                    ui.error_msg = (not commits and error_msg) or nil
                    commit_gui_state.selected_commits[key] = versioned_commits[1].sha
                end
            end)
        end
    end
    
    return true
end

-- Render commit selection GUI
local function RenderCommitGUI()
    if not commit_gui_state.ctx or not commit_gui_state.open then
        return false
    end
    
    local ctx = commit_gui_state.ctx
    
    -- Apply custom theme
    ApplyCustomTheme(ctx)
    
    -- Set fixed window size (not resizable, not collapsible)
    -- Adjust height based on whether installation details are expanded
    local window_height = 356
    if #commit_gui_state.repos_to_select > 1 then
        window_height = 356 + (#commit_gui_state.repos_to_select - 1) * 78
    end
    if commit_gui_state.installing then
        window_height = 600 -- Expanded during installation
    elseif commit_gui_state.install_log_expanded and #commit_gui_state.install_log > 0 then
        window_height = 600 -- Expanded after installation
    end
    
    r.ImGui_SetNextWindowSize(ctx, 600, window_height, r.ImGui_Cond_Always())
    r.ImGui_SetNextWindowPos(ctx, 100, 100, r.ImGui_Cond_FirstUseEver())
    
    -- Window flags: no resize, no collapse
    local window_flags = r.ImGui_WindowFlags_NoResize() | r.ImGui_WindowFlags_NoCollapse() | r.ImGui_WindowFlags_NoScrollbar()
    local visible, open = r.ImGui_Begin(ctx, "Cool Reaper Script Installer", true, window_flags)
    commit_gui_state.open = open
    
    if not visible then
        PopCustomTheme(ctx)
        return open
    end
    
    if #commit_gui_state.repos_to_select == 0 then
        r.ImGui_Text(ctx, "No repositories to configure.")
        r.ImGui_End(ctx)
        PopCustomTheme(ctx)
        return open
    end
    
    local frame_padding_x, frame_padding_y = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())
    local default_line_height = r.ImGui_GetTextLineHeight(ctx)
    local frame_height = frame_padding_y * 2 + default_line_height
    local window_width = r.ImGui_GetWindowWidth(ctx)
    local window_padding = 24
    local dropdown_width = 200
    local cursor_x = window_width - dropdown_width - window_padding
    
    for _, repo_key in ipairs(commit_gui_state.repos_to_select) do
        local repo = REPOSITORIES[repo_key]
        local ui = commit_gui_state.repo_ui[repo_key] or {
            loading = true, error_msg = nil, use_releases = false, releases = {}, commits = {},
        }
        local display_name = (repo and repo.display) or (repo and repo.repo) or repo_key
        local selected = commit_gui_state.selected_repos[repo_key] ~= false
        local start_y = r.ImGui_GetCursorPosY(ctx)
        
        r.ImGui_SetCursorPosY(ctx, start_y + 8)
        local checked_clicked, checked = r.ImGui_Checkbox(ctx, "##install_" .. repo_key, selected)
        if checked_clicked then
            commit_gui_state.selected_repos[repo_key] = checked and true or false
            selected = checked and true or false
        end
        
        r.ImGui_SameLine(ctx, 0, 10)
        local title_x = r.ImGui_GetCursorPosX(ctx)
        local title_color = selected and 0x2D4F47FF or 0x6A7A76FF
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), title_color)
        if commit_gui_state.title_font then
            r.ImGui_PushFont(ctx, commit_gui_state.title_font, 28)
        else
            r.ImGui_PushFont(ctx, nil, 28)
        end
        local title_line_height = r.ImGui_GetTextLineHeight(ctx)
        local max_height = math.max(frame_height, title_line_height)
        local title_y = start_y + (max_height - title_line_height) / 2
        local dropdown_y = start_y + (max_height - frame_height) / 2
        r.ImGui_SetCursorPosY(ctx, title_y)
        r.ImGui_Text(ctx, display_name)
        r.ImGui_PopFont(ctx)
        r.ImGui_PopStyleColor(ctx)
        
        r.ImGui_SameLine(ctx)
        r.ImGui_SetCursorPosX(ctx, cursor_x)
        r.ImGui_SetCursorPosY(ctx, dropdown_y)
        if not selected and r.ImGui_BeginDisabled then
            r.ImGui_BeginDisabled(ctx)
        end
        
        local current_selected = nil
        local current_selected_index = 0
        local preview_text = "Select Version..."
        
        if ui.use_releases then
            current_selected = commit_gui_state.selected_releases[repo_key]
            if current_selected and #ui.releases > 0 then
                for i, release in ipairs(ui.releases) do
                    if release.tag == current_selected then
                        current_selected_index = i - 1
                        preview_text = release.version or release.tag
                        break
                    end
                end
            elseif ui.loading then
                preview_text = "Loading..."
            elseif ui.error_msg then
                preview_text = "Error loading"
            end
        else
            current_selected = commit_gui_state.selected_commits[repo_key]
            if current_selected and #ui.commits > 0 then
                for i, commit in ipairs(ui.commits) do
                    if commit.sha == current_selected then
                        current_selected_index = i - 1
                        preview_text = commit.version or "Unknown"
                        break
                    end
                end
            elseif ui.loading then
                preview_text = "Loading..."
            elseif ui.error_msg then
                preview_text = "Error loading"
            end
        end
        
        r.ImGui_PushItemWidth(ctx, 200)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgHovered(), 0x55555533)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgActive(), 0x55555533)
        
        if r.ImGui_BeginCombo(ctx, "##VersionCombo" .. repo_key, preview_text, r.ImGui_ComboFlags_None()) then
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Header(), 0x55555533)
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), 0x55555533)
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), 0x55555533)
            
            if ui.use_releases then
                for i, release in ipairs(ui.releases) do
                    local is_selected = (current_selected_index == i - 1)
                    local version_display = release.version or release.tag
                    if r.ImGui_Selectable(ctx, version_display, is_selected) then
                        commit_gui_state.selected_releases[repo_key] = release.tag
                    end
                    if is_selected then
                        r.ImGui_SetItemDefaultFocus(ctx)
                    end
                end
            else
                for i, commit in ipairs(ui.commits) do
                    local is_selected = (current_selected_index == i - 1)
                    local version_display = commit.version or "Unknown"
                    if r.ImGui_Selectable(ctx, version_display, is_selected) then
                        commit_gui_state.selected_commits[repo_key] = commit.sha
                    end
                    if is_selected then
                        r.ImGui_SetItemDefaultFocus(ctx)
                    end
                end
            end
            
            r.ImGui_PopStyleColor(ctx, 3)
            r.ImGui_EndCombo(ctx)
        end
        
        r.ImGui_PopStyleColor(ctx, 2)
        r.ImGui_PopItemWidth(ctx)
        if not selected and r.ImGui_EndDisabled then
            r.ImGui_EndDisabled(ctx)
        end
        r.ImGui_SetCursorPosY(ctx, start_y + max_height + 4)
        r.ImGui_SetCursorPosX(ctx, title_x)
        DrawLicenseChip(ctx, repo_key, commit_gui_state.license_ui[repo_key])
        r.ImGui_Dummy(ctx, 0, 8)
    end
    
    r.ImGui_Spacing(ctx)
    r.ImGui_Spacing(ctx)
    r.ImGui_Spacing(ctx)
    
    -- Show installation progress or install button
    if commit_gui_state.installing then
        -- Installation progress display
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)
        
        -- Progress bar
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x2D4F47FF) -- Accent color
        r.ImGui_Text(ctx, "Installing...")
        r.ImGui_PopStyleColor(ctx)
        r.ImGui_Spacing(ctx)
        
        -- Progress bar with accent color
        local progress = math.max(0.0, math.min(1.0, commit_gui_state.install_progress)) -- Clamp between 0 and 1
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PlotHistogram(), 0x2D4F47FF) -- Accent color for progress bar
        r.ImGui_ProgressBar(ctx, progress, -1, 0, string.format("%.0f%%", progress * 100))
        r.ImGui_PopStyleColor(ctx)
        
        r.ImGui_Spacing(ctx)
        
        -- Expandable installation log (moved below progress bar)
        -- Show log if there are entries, even after installation completes
        if #commit_gui_state.install_log > 0 then
            -- Collapsible header showing currently installing file
            local header_text = commit_gui_state.install_current_file ~= "" and commit_gui_state.install_current_file or "Installation Details"
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Header(), 0x00000000) -- Transparent header
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), 0x00000000) -- Transparent hover
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), 0x00000000) -- Transparent active
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xE0E0E0FF) -- Light text for header
            
            -- Force expanded during installation (uncollapsible), allow collapsing after installation
            local is_expanded = false
            
            if commit_gui_state.installing then
                -- During installation: force expanded state (uncollapsible)
                -- Use SetNextItemOpen to ensure it's always open
                r.ImGui_SetNextItemOpen(ctx, true, r.ImGui_Cond_Always())
                is_expanded = r.ImGui_CollapsingHeader(ctx, header_text, r.ImGui_TreeNodeFlags_DefaultOpen())
                -- Always show content during installation
                is_expanded = true
                commit_gui_state.install_log_expanded = true
            else
                -- After installation: allow collapsing
                is_expanded = r.ImGui_CollapsingHeader(ctx, header_text, nil)
            end
            
            r.ImGui_PopStyleColor(ctx, 4)
            
            -- Always show content during installation, or if expanded after installation
            if commit_gui_state.installing or is_expanded then
                commit_gui_state.install_log_expanded = true
                r.ImGui_Spacing(ctx)
                
                -- Scrollable child window for the log
                local child_height = 300 -- Fixed height for scrollable area (2x original)
                if r.ImGui_BeginChild(ctx, "InstallLog", -1, child_height, 0, r.ImGui_WindowFlags_None()) then
                    for i, log_entry in ipairs(commit_gui_state.install_log) do
                        r.ImGui_PushID(ctx, i)
                        
                        -- File name
                        if log_entry.status == "success" then
                            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x4CAF50FF) -- Green for success
                            r.ImGui_Text(ctx, "✓ ")
                            r.ImGui_PopStyleColor(ctx)
                            r.ImGui_SameLine(ctx)
                            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xE0E0E0FF) -- Light text
                            r.ImGui_Text(ctx, log_entry.file)
                            r.ImGui_PopStyleColor(ctx)
                        else
                            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFF6B6BFF) -- Red for failed
                            r.ImGui_Text(ctx, "✗ ")
                            r.ImGui_PopStyleColor(ctx)
                            r.ImGui_SameLine(ctx)
                            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xE0E0E0FF) -- Light text
                            r.ImGui_Text(ctx, log_entry.file)
                            r.ImGui_PopStyleColor(ctx)
                            
                            -- Show error message if available
                            if log_entry.message and log_entry.message ~= "" then
                                r.ImGui_SameLine(ctx)
                                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xB0B0B0FF) -- Secondary text
                                r.ImGui_Text(ctx, " - " .. log_entry.message)
                                r.ImGui_PopStyleColor(ctx)
                            end
                        end
                        
                        r.ImGui_PopID(ctx)
                    end
                    
                    r.ImGui_EndChild(ctx)
                end
            else
                commit_gui_state.install_log_expanded = false
            end
        end
        
        -- During installation, don't show duplicate current file/status info (already in header)
        -- Only show these after installation completes
        if not commit_gui_state.installing then
            r.ImGui_Spacing(ctx)
            
            -- Current file and status (only after installation)
            if commit_gui_state.install_current_file ~= "" then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xE0E0E0FF) -- Light text
                r.ImGui_TextWrapped(ctx, commit_gui_state.install_current_file)
                r.ImGui_PopStyleColor(ctx)
            end
            
            if commit_gui_state.install_status ~= "" then
                r.ImGui_Spacing(ctx)
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xB0B0B0FF) -- Secondary text color
                r.ImGui_Text(ctx, commit_gui_state.install_status)
                r.ImGui_PopStyleColor(ctx)
            end
            
            r.ImGui_Spacing(ctx)
        else
            r.ImGui_Spacing(ctx)
        end
        
        -- Success/Failed counts
        if commit_gui_state.install_total > 0 then
            local current_file_num = math.floor(commit_gui_state.install_progress * commit_gui_state.install_total) + 1
            if current_file_num > commit_gui_state.install_total then
                current_file_num = commit_gui_state.install_total
            end
            
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xB0B0B0FF) -- Secondary text color
            r.ImGui_Text(ctx, string.format("File %d of %d", current_file_num, commit_gui_state.install_total))
            r.ImGui_PopStyleColor(ctx)
            
            if commit_gui_state.install_success_count > 0 or commit_gui_state.install_failed_count > 0 then
                r.ImGui_SameLine(ctx)
                r.ImGui_Text(ctx, " | ")
                r.ImGui_SameLine(ctx)
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x4CAF50FF) -- Green for success
                r.ImGui_Text(ctx, string.format("✓ %d", commit_gui_state.install_success_count))
                r.ImGui_PopStyleColor(ctx)
                
                if commit_gui_state.install_failed_count > 0 then
                    r.ImGui_SameLine(ctx)
                    r.ImGui_Text(ctx, " | ")
                    r.ImGui_SameLine(ctx)
                    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFF6B6BFF) -- Red for failed
                    r.ImGui_Text(ctx, string.format("✗ %d", commit_gui_state.install_failed_count))
                    r.ImGui_PopStyleColor(ctx)
                end
            end
        end
    else
        -- Install button (centered, full width)
        local selected_keys = GetSelectedRepoKeys()
        local can_finish = #selected_keys > 0
        for _, repo_key in ipairs(selected_keys) do
            local ui = commit_gui_state.repo_ui[repo_key]
            if not ui or ui.loading then
                can_finish = false
                break
            end
            if ui.use_releases then
                if not commit_gui_state.selected_releases[repo_key] then
                    can_finish = false
                    break
                end
            elseif not commit_gui_state.selected_commits[repo_key] then
                can_finish = false
                break
            end
        end
        
        if can_finish then
            r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), 12.0, 10.0)
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x2D4F47FF) -- Accent color for primary button
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x3A6B5FFF) -- Lighter accent on hover
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x255A4FFF) -- Darker accent when active
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFFFFFF) -- White text on accent button
            
            -- Center the button
            local button_width = 200
            local content_width = r.ImGui_GetContentRegionAvail(ctx)
            local button_x = (content_width - button_width) / 2
            r.ImGui_SetCursorPosX(ctx, r.ImGui_GetCursorPosX(ctx) + button_x)
            
            if r.ImGui_Button(ctx, "Install", button_width, 0) then
                commit_gui_state.installing = true
                InstallAllFiles()
            end
            
            r.ImGui_PopStyleColor(ctx, 4)
            r.ImGui_PopStyleVar(ctx)
        elseif #GetSelectedRepoKeys() == 0 then
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xB0B0B0FF)
            r.ImGui_Text(ctx, "Tick at least one script to install.")
            r.ImGui_PopStyleColor(ctx)
        else
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xB0B0B0FF) -- Secondary text color
            r.ImGui_Text(ctx, "Please select a version.")
            r.ImGui_PopStyleColor(ctx)
        end

        r.ImGui_Spacing(ctx)
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), 10.0, 8.0)
        local py_button_width = 200
        local py_content_width = r.ImGui_GetContentRegionAvail(ctx)
        local py_button_x = (py_content_width - py_button_width) / 2
        r.ImGui_SetCursorPosX(ctx, r.ImGui_GetCursorPosX(ctx) + py_button_x)
        local py_label = (commit_gui_state.python_path ~= "" and "Reinstall Python 3" or "Install Python 3")
        if r.ImGui_Button(ctx, py_label, py_button_width, 0) then
            StartPythonInstall()
        end
        r.ImGui_PopStyleVar(ctx)

        r.ImGui_Spacing(ctx)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xB0B0B0FF)
        if commit_gui_state.python_path ~= "" then
            local ver = commit_gui_state.python_version ~= "" and (" " .. commit_gui_state.python_version) or ""
            r.ImGui_TextWrapped(ctx, "Private Python" .. ver .. " is installed next to Cool Reaper Scripts.")
        else
            r.ImGui_TextWrapped(ctx, "Optional: install a private Python 3 (~25 MB) for Split to Stems. No admin, not added to PATH.")
        end
        r.ImGui_TextWrapped(ctx, "WAV files work without ffmpeg. Other formats still need ffmpeg on PATH.")
        r.ImGui_PopStyleColor(ctx)
        
        -- Show installation log after installation completes (keep it visible)
        if not commit_gui_state.installing and #commit_gui_state.install_log > 0 then
            r.ImGui_Spacing(ctx)
            r.ImGui_Separator(ctx)
            r.ImGui_Spacing(ctx)
            
            -- Collapsible header for completed installation
            local header_text = "Installation Details"
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Header(), 0x00000000) -- Transparent header
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), 0x00000000) -- Transparent hover
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), 0x00000000) -- Transparent active
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xE0E0E0FF) -- Light text for header
            
            local is_expanded = r.ImGui_CollapsingHeader(ctx, header_text, nil)
            r.ImGui_PopStyleColor(ctx, 4)
            
            -- Update expanded state
            commit_gui_state.install_log_expanded = is_expanded
            
            if is_expanded then
                r.ImGui_Spacing(ctx)
                
                -- Scrollable child window for the log
                local child_height = 300 -- Fixed height for scrollable area (2x original)
                if r.ImGui_BeginChild(ctx, "InstallLogCompleted", -1, child_height, 0, r.ImGui_WindowFlags_None()) then
                    for i, log_entry in ipairs(commit_gui_state.install_log) do
                        r.ImGui_PushID(ctx, i)
                        
                        -- File name and path
                        if log_entry.status == "success" then
                            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x4CAF50FF) -- Green for success
                            r.ImGui_Text(ctx, "✓ ")
                            r.ImGui_PopStyleColor(ctx)
                            r.ImGui_SameLine(ctx)
                            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xE0E0E0FF) -- Light text
                            r.ImGui_Text(ctx, log_entry.path or log_entry.file)
                            r.ImGui_PopStyleColor(ctx)
                        else
                            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFF6B6BFF) -- Red for failed
                            r.ImGui_Text(ctx, "✗ ")
                            r.ImGui_PopStyleColor(ctx)
                            r.ImGui_SameLine(ctx)
                            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xE0E0E0FF) -- Light text
                            r.ImGui_Text(ctx, log_entry.path or log_entry.file)
                            r.ImGui_PopStyleColor(ctx)
                            
                            -- Show error message if available
                            if log_entry.message and log_entry.message ~= "" then
                                r.ImGui_SameLine(ctx)
                                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xB0B0B0FF) -- Secondary text
                                r.ImGui_Text(ctx, " - " .. log_entry.message)
                                r.ImGui_PopStyleColor(ctx)
                            end
                        end
                        
                        r.ImGui_PopID(ctx)
                    end
                    
                    r.ImGui_EndChild(ctx)
                end
            else
                commit_gui_state.install_log_expanded = false
            end
        end
    end
    
    -- Show modal popup if needed
    if commit_gui_state.show_modal then
        -- Open the popup on first show
        if not r.ImGui_IsPopupOpen(ctx, commit_gui_state.modal_title) then
            r.ImGui_OpenPopup(ctx, commit_gui_state.modal_title)
        end
        
        -- Calculate modal size: 20% smaller width than installer window (600 * 0.8 = 480)
        local installer_width = 600
        local modal_width = installer_width * 0.8
        local modal_height = 360
        
        -- Get installer window position and size to center modal
        local installer_pos_x, installer_pos_y = r.ImGui_GetWindowPos(ctx)
        local installer_size_x, installer_size_y = r.ImGui_GetWindowSize(ctx)
        
        -- Center modal on installer window
        local modal_pos_x = installer_pos_x + (installer_size_x - modal_width) / 2
        local modal_pos_y = installer_pos_y + (installer_size_y - modal_height) / 2
        
        r.ImGui_SetNextWindowPos(ctx, modal_pos_x, modal_pos_y, r.ImGui_Cond_Always())
        r.ImGui_SetNextWindowSize(ctx, modal_width, modal_height, r.ImGui_Cond_Always())
        
        -- Render modal popup
        local modal_flags = r.ImGui_WindowFlags_NoResize() | r.ImGui_WindowFlags_NoMove()
        if r.ImGui_BeginPopupModal(ctx, commit_gui_state.modal_title, nil, modal_flags) then
            r.ImGui_Spacing(ctx)
            
            -- Message text (scrollable so the OK button stays visible)
            local _, avail_y = r.ImGui_GetContentRegionAvail(ctx)
            local child_height = math.max(80, avail_y - 56)
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xE0E0E0FF) -- Light text
            if r.ImGui_BeginChild(ctx, "ModalMessage", -1, child_height, 0, r.ImGui_WindowFlags_None()) then
                r.ImGui_TextWrapped(ctx, commit_gui_state.modal_message)
                r.ImGui_EndChild(ctx)
            end
            r.ImGui_PopStyleColor(ctx)
            
            r.ImGui_Spacing(ctx)
            r.ImGui_Separator(ctx)
            r.ImGui_Spacing(ctx)
            
            -- OK button (centered)
            local button_width = 100
            local content_width = r.ImGui_GetContentRegionAvail(ctx)
            local button_x = (content_width - button_width) / 2
            r.ImGui_SetCursorPosX(ctx, r.ImGui_GetCursorPosX(ctx) + button_x)
            
            r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), 10.0, 8.0)
            local modal_color_count = 0
            if commit_gui_state.modal_type == "success" then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x2D4F47FF) -- Accent color
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x3A6B5FFF)
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x255A4FFF)
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFFFFFF) -- White text
                modal_color_count = 4
            else
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x404040FF) -- Gray for error
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x505050FF)
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x353535FF)
                modal_color_count = 3
            end
            
            if r.ImGui_Button(ctx, "OK", button_width, 0) then
                commit_gui_state.show_modal = false
                r.ImGui_CloseCurrentPopup(ctx)
            end
            
            if modal_color_count > 0 then
                r.ImGui_PopStyleColor(ctx, modal_color_count)
            end
            r.ImGui_PopStyleVar(ctx)
            
            r.ImGui_EndPopup(ctx)
        end
    end
    
    r.ImGui_End(ctx)
    
    -- Pop custom theme after window ends
    PopCustomTheme(ctx)
    
    if open and commit_gui_state.open then
        r.defer(RenderCommitGUI)
    else
        -- Cleanup when window is closed
        if commit_gui_state.ctx then
            if r.APIExists("ImGui_DestroyContext") then
                r.ImGui_DestroyContext(commit_gui_state.ctx)
            end
            commit_gui_state.ctx = nil
        end
    end
    
    return open and commit_gui_state.open
end

-- ============================================================================
-- CHECK DEPENDENCIES
-- ============================================================================

local function CheckDependencies()
    local OS = r.GetOS()
    local cmd
    
    if OS:match("Win") then
        cmd = "curl --version"
    else
        cmd = "/usr/bin/curl --version"
    end
    
    local result = r.ExecProcess(cmd, 5000)
    
    if not result or result == "" then
        -- Try alternative check
        local handle = io.popen(cmd, "r")
        if handle then
            result = handle:read("*all")
            handle:close()
        end
    end
    
    if not result or result == "" then
        r.ShowMessageBox(
            "curl is not available on your system.\n\n" ..
            "Please install curl to use this installer.\n\n" ..
            "Windows: Download from https://curl.se/windows/\n" ..
            "macOS/Linux: Usually pre-installed, or install via package manager",
            "Missing Dependency",
            0
        )
        return false
    end
    
    return true
end

-- ============================================================================
-- MAIN EXECUTION
-- ============================================================================

-- Check dependencies
if not CheckDependencies() then
    return
end

-- Build repository list for confirmation dialog
local function GetReposList()
    local repos_list = {}
    local repos_seen = {}
    
    for _, file_info in ipairs(FILES_TO_INSTALL) do
        local repo_key = file_info.repo or next(REPOSITORIES)
        if not repos_seen[repo_key] then
            repos_seen[repo_key] = true
            local repo = REPOSITORIES[repo_key]
            table.insert(repos_list, string.format("  • %s/%s (%s)", repo.user, repo.repo, repo.branch))
        end
    end
    
    return table.concat(repos_list, "\n")
end

-- Start commit selection GUI or proceed with installation
if #FILES_TO_INSTALL == 0 then
    r.ShowMessageBox(
        "No files configured for installation.\n\n" ..
        "Please edit the script and add files to FILES_TO_INSTALL table.",
        "No Files Configured",
        0
    )
else
    -- Try to initialize commit selection GUI
    if InitCommitGUI() then
        -- Show GUI for commit selection
        r.defer(RenderCommitGUI)
    else
        -- Fallback: use default branch and show confirmation
        local repos_list_text = GetReposList()
        local confirm = r.ShowMessageBox(
            string.format(
                "This will install %d file(s) from:\n\n%s\n\n" ..
                "Files will be downloaded and installed to your REAPER resource folder.\n" ..
                "Scripts will be automatically registered in the Action List.\n\n" ..
                "Continue?",
                #FILES_TO_INSTALL,
                repos_list_text
            ),
            "BRYAN Script Installer",
            4 -- Yes/No buttons
        )
        
        if confirm == 6 then -- Yes (6 = Yes on Windows, 6 = Yes on macOS)
            InstallAllFiles()
        end
    end
end

