-- @description BRYAN Script Installer - Mini ReaPack Alternative
-- @version 1.0.0
-- @author bryan
-- @about Downloads and installs scripts, JSFX, and assets from GitHub repo. Automatically registers scripts in Action List.
-- @changelog Initial release

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
        branch = "main"          -- Branch name (main, master, etc.)
    },
    
    -- Add more repositories as needed
    -- scripts = {
    --     user = "BryanChi",
    --     repo = "MyScriptsRepo",
    --     branch = "main"
    -- },
    -- effects = {
    --     user = "BryanChi",
    --     repo = "MyEffectsRepo",
    --     branch = "main"
    -- },
}

-- Selected commits per repository (commit hash or branch name)
local SELECTED_COMMITS = {}

-- Main script name (for user instructions)
local MAIN_SCRIPT_NAME = "Vertical FX List"

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
    },
    
    -- Configuration files
    {
        url_path = "style_presets_FACTORY.lua",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/style_presets_FACTORY.lua",
        script_type = "lua",
    },

    
    -- Function files
    {
        url_path = "Vertical FX List Resources/Functions/General Functions.Lua",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/Functions/General Functions.Lua",
        script_type = "lua",
    },
    {
        url_path = "Vertical FX List Resources/Functions/FX Buttons.lua",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/Functions/FX Buttons.lua",
        script_type = "lua",
    },
    {
        url_path = "Vertical FX List Resources/Functions/Sends.lua",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/Functions/Sends.lua",
        script_type = "lua",
    },
    {
        url_path = "Vertical FX List Resources/Functions/FX Parser.lua",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/FX Parser.lua",
    },

    
    -- Image assets (required)
    {
        url_path = "Vertical FX List Resources/star.png",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/star.png",
    },
    {
        url_path = "Vertical FX List Resources/starHollow.png",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/starHollow.png",
    },
    {
        url_path = "Vertical FX List Resources/send.png",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/send.png",
    },
    {
        url_path = "Vertical FX List Resources/receive.png",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/receive.png",
    },
    {
        url_path = "Vertical FX List Resources/show.png",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/show.png",
    },
    {
        url_path = "Vertical FX List Resources/hide.png",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/hide.png",
    },
    {
        url_path = "Vertical FX List Resources/link.png",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/link.png",
    },
    {
        url_path = "Vertical FX List Resources/snapshot.png",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/snapshot.png",
    },
    {
        url_path = "Vertical FX List Resources/camera.png",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/camera.png",
    },
    {
        url_path = "Vertical FX List Resources/folder.png",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/folder.png",
    },
    {
        url_path = "Vertical FX List Resources/folder_open.png",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/folder_open.png",
    },
    {
        url_path = "Vertical FX List Resources/settings.png",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/settings.png",
    },
    
    -- Image assets (optional - script has fallbacks)
    {
        url_path = "Vertical FX List Resources/copy.png",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/copy.png",
    },
    {
        url_path = "Vertical FX List Resources/search.png",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/search.png",
    },
    {
        url_path = "Vertical FX List Resources/trash.png",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/trash.png",
    },
    {
        url_path = "Vertical FX List Resources/volume.png",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/volume.png",
    },
    {
        url_path = "Vertical FX List Resources/graph.png",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/graph.png",
    },
    {
        url_path = "Vertical FX List Resources/undo.png",
        target_path = "Scripts/CoolReaperScripts/Vertical FX List/Vertical FX List Resources/undo.png",
    },
    
}

-- Commit selection GUI state (define early so installers can update it)
local commit_gui_state = {
    open = true,
    ctx = nil,
    commits = {},
    selected_commits = {}, -- {repo_key = commit_sha}
    loading = false,
    error_msg = nil,
    current_repo_index = 1,
    repos_to_select = {},
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
    -- Modal popup
    show_modal = false,
    modal_title = "",
    modal_message = "",
    modal_type = "success" -- "success" or "error"
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

local function InstallFile(file_info, progress_callback)
    local url_path = file_info.url_path
    local target_path = file_info.target_path
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
    local filename = target_path:match("([^/\\]+)$") or url_path:match("([^/\\]+)$")
    
    -- Special handling for Vertical FX List script
    local is_vertical_fx_list = (filename == "FXD_Vertical FX list.lua")
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
    started = false
}

local function ShowInstallSummary()
    local results = install_state.results
    
    -- Update GUI to show completion
    if commit_gui_state.ctx then
        commit_gui_state.install_progress = 1.0
        commit_gui_state.install_success_count = #results.success
        commit_gui_state.install_failed_count = #results.failed
        
        -- Show modal popup with installation summary
        if #results.success > 0 then
            local message = string.format(
                "Installation Complete!\n\n" ..
                "Successfully installed: %d file(s)",
                #results.success
            )
            
            if #results.failed > 0 then
                message = message .. string.format("\nFailed: %d file(s)", #results.failed)
            end
            
            message = message .. string.format(
                "\n\nTo start the script:\n" ..
                "1. Open Actions → Show Action List\n" ..
                "2. Search for '%s'\n" ..
                "3. Run the script from the list",
                MAIN_SCRIPT_NAME
            )
            
            commit_gui_state.modal_title = "Installation Complete"
            commit_gui_state.modal_message = message
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
        install_state = {files = {}, current_index = 0, results = {success = {}, failed = {}}, total = 0, started = false}
        
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
    if not install_state.started or install_state.current_index >= install_state.total then
        -- Update GUI progress to 100%
        if commit_gui_state.ctx then
            commit_gui_state.install_progress = 1.0
            commit_gui_state.install_status = "Installation complete!"
        end
        ShowInstallSummary()
        return -- Done
    end
    
    local i = install_state.current_index + 1
    install_state.current_index = i
    local file_info = install_state.files[i]
    local results = install_state.results
    
    -- Update GUI progress
    if commit_gui_state.ctx then
        commit_gui_state.install_progress = i / install_state.total
        commit_gui_state.install_current_file = file_info.url_path:match("([^/\\]+)$") or file_info.url_path
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
    
    local file_name = file_info.url_path:match("([^/\\]+)$") or file_info.url_path
    local target_path = file_info.target_path or file_info.url_path
    
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
    
    -- Initialize installation state
    install_state.files = FILES_TO_INSTALL
    install_state.current_index = 0
    install_state.results = {success = {}, failed = {}}
    install_state.total = #FILES_TO_INSTALL
    install_state.started = true
    
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
    -- Pop all style colors (14 colors - 9 original + 3 title bar + 2 header colors)
    for i = 1, 14 do
        r.ImGui_PopStyleColor(ctx)
    end
    -- Pop all style vars (19 vars)
    for i = 1, 19 do
        r.ImGui_PopStyleVar(ctx)
    end
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
    
    -- Create ImGui context
    commit_gui_state.ctx = r.ImGui_CreateContext("Cool Reaper Script Installer - Commit Selection")
    
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
    
    -- Auto-load commits for the first repository
    if #commit_gui_state.repos_to_select > 0 then
        local current_repo_key = commit_gui_state.repos_to_select[commit_gui_state.current_repo_index]
        local repo = REPOSITORIES[current_repo_key]
        if repo then
            commit_gui_state.loading = true
            commit_gui_state.error_msg = nil
            commit_gui_state.commits = {}
            
            -- Fetch commits in background (non-blocking)
            r.defer(function()
                local commits, error_msg = FetchCommits(repo.user, repo.repo, repo.branch)
                commit_gui_state.loading = false
                if commits then
                    -- Deduplicate by display string (date + message) and extract versions from commit messages
                    local unique_commits = {}
                    local seen_displays = {}
                    local versioned_commits = {}
                    
                    for i, commit in ipairs(commits) do
                        local display = string.format("%s - %s", commit.date, commit.message)
                        
                        -- Check if we've seen this display string before
                        if not seen_displays[display] then
                            seen_displays[display] = true
                            table.insert(unique_commits, commit)
                            
                        -- Extract version from commit message (pattern: ##VerX.X##)
                        local version = ExtractVersionFromMessage(commit.message)
                        if version then
                            commit.version = version  -- Add version to commit object
                            table.insert(versioned_commits, commit)
                        end
                    end
                    end
                    
                commit_gui_state.commits = versioned_commits
                -- Default to latest versioned commit
                if #versioned_commits > 0 then
                    commit_gui_state.selected_commits[current_repo_key] = versioned_commits[1].sha
                end
                else
                    commit_gui_state.error_msg = error_msg or "Failed to load commits"
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
    local window_height = 200 -- Default height
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
    
    local current_repo_key = commit_gui_state.repos_to_select[commit_gui_state.current_repo_index]
    if not current_repo_key then
        r.ImGui_Text(ctx, "No repositories to configure.")
        r.ImGui_End(ctx)
        PopCustomTheme(ctx)
        return open
    end
    
    local repo = REPOSITORIES[current_repo_key]
    
    -- Top row: Title on left, Version dropdown on right (vertically aligned)
    -- Store starting Y position
    local start_y = r.ImGui_GetCursorPosY(ctx)
    
    -- Calculate frame height for alignment (dropdown uses frame padding)
    local frame_padding_x, frame_padding_y = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())
    local default_line_height = r.ImGui_GetTextLineHeight(ctx)
    local frame_height = frame_padding_y * 2 + default_line_height -- Approximate dropdown height
    
    -- Draw title on left with bold font
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x2D4F47FF) -- Accent color
    
    if commit_gui_state.title_font then
        r.ImGui_PushFont(ctx, commit_gui_state.title_font, 28) -- Use created bold font with explicit size
    else
        r.ImGui_PushFont(ctx, nil, 28) -- Fallback: use size without bold
    end
    
    local title_line_height = r.ImGui_GetTextLineHeight(ctx)
    -- Align both title and dropdown to the same center
    local max_height = math.max(frame_height, title_line_height)
    local title_y = start_y + (max_height - title_line_height) / 2
    local dropdown_y = start_y + (max_height - frame_height) / 2
    
    r.ImGui_SetCursorPosY(ctx, title_y)
    r.ImGui_Text(ctx, "Vertical FX List")
    r.ImGui_PopFont(ctx)
    r.ImGui_PopStyleColor(ctx)
    
    r.ImGui_SameLine(ctx)
    -- Push cursor to right side
    local window_width = r.ImGui_GetWindowWidth(ctx)
    local window_padding = 24 -- Account for window padding (12px on each side)
    local dropdown_width = 200
    local cursor_x = window_width - dropdown_width - window_padding
    r.ImGui_SetCursorPosX(ctx, cursor_x)
    r.ImGui_SetCursorPosY(ctx, dropdown_y)
    
    -- Version dropdown on the right
    local current_selected_sha = commit_gui_state.selected_commits[current_repo_key]
    local current_selected_index = 0
    local preview_text = "Select Version..."
    
    -- Build preview text and find current index
    if current_selected_sha and #commit_gui_state.commits > 0 then
        for i, commit in ipairs(commit_gui_state.commits) do
            if commit.sha == current_selected_sha then
                current_selected_index = i - 1 -- ImGui uses 0-based indexing
                preview_text = commit.version or "Unknown"
                break
            end
        end
    elseif commit_gui_state.loading then
        preview_text = "Loading..."
    elseif commit_gui_state.error_msg then
        preview_text = "Error loading"
    end
    
    -- Dropdown combo
    r.ImGui_PushItemWidth(ctx, 200)
    
    -- Set transparent hover colors for dropdown items
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgHovered(), 0x55555533) -- Transparent hover
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgActive(), 0x55555533) -- Transparent active
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x55555533) -- Transparent active
    

    if r.ImGui_BeginCombo(ctx, "##VersionCombo", preview_text, r.ImGui_ComboFlags_None()) then
        -- Set selectable hover/active colors
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Header(), 0x55555533) -- Transparent hover for selectables
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), 0x55555533) -- Transparent hover for selectables
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), 0x55555533) -- Transparent active for selectables
        
        for i, commit in ipairs(commit_gui_state.commits) do
            local is_selected = (current_selected_index == i - 1)
            local version_display = commit.version or "Unknown"

            if r.ImGui_Selectable(ctx, version_display, is_selected) then
                commit_gui_state.selected_commits[current_repo_key] = commit.sha
            end
            if r.ImGui_IsItemHovered(ctx) then 
                HOVER_VERSION = version_display
            end
            if is_selected then
                r.ImGui_SetItemDefaultFocus(ctx)
            end
        end
        
        -- Pop selectable colors
        r.ImGui_PopStyleColor(ctx, 3)
        r.ImGui_EndCombo(ctx)
    end
    
    -- Pop hover colors
    r.ImGui_PopStyleColor(ctx, 3)
    r.ImGui_PopItemWidth(ctx)
    
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
        local can_finish = (current_selected_sha ~= nil)
        
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
                -- Apply selected commits
                for repo_key, commit_ref in pairs(commit_gui_state.selected_commits) do
                    SELECTED_COMMITS[repo_key] = commit_ref
                end
                -- Don't close window, keep it open to show progress
                commit_gui_state.installing = true
                -- Start installation
                InstallAllFiles()
            end
            
            r.ImGui_PopStyleColor(ctx, 4)
            r.ImGui_PopStyleVar(ctx)
        else
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xB0B0B0FF) -- Secondary text color
            r.ImGui_Text(ctx, "Please select a version.")
            r.ImGui_PopStyleColor(ctx)
        end
        
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
        local modal_height = 300 -- Bigger height
        
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
            
            -- Message text
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xE0E0E0FF) -- Light text
            r.ImGui_TextWrapped(ctx, commit_gui_state.modal_message)
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
            if commit_gui_state.modal_type == "success" then
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x2D4F47FF) -- Accent color
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x3A6B5FFF)
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x255A4FFF)
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFFFFFF) -- White text
            else
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x404040FF) -- Gray for error
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x505050FF)
                r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x353535FF)
            end
            
            if r.ImGui_Button(ctx, "OK", button_width, 0) then
                commit_gui_state.show_modal = false
                r.ImGui_CloseCurrentPopup(ctx)
            end
            
            r.ImGui_PopStyleColor(ctx, 4)
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

