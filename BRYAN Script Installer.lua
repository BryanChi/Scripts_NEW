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

-- Helper function to build raw GitHub URL for a repository
local function GetRepoRawBase(repo_key)
    local repo = REPOSITORIES[repo_key]
    if not repo then
        -- Fallback to first repo if key not found
        local first_key = next(REPOSITORIES)
        repo = REPOSITORIES[first_key]
    end
    return string.format("https://raw.githubusercontent.com/%s/%s/%s", 
                         repo.user, repo.repo, repo.branch)
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
        target_path = "Scripts/BRYAN's SCRIPTS/FXD_Vertical FX list.lua",
        script_type = "lua",
    },
    
    -- Configuration files
    {
        url_path = "fx_favorites.txt",
        target_path = "Scripts/BRYAN's SCRIPTS/fx_favorites.txt",
    },
    {
        url_path = "style_presets_FACTORY.lua",
        target_path = "Scripts/BRYAN's SCRIPTS/style_presets_FACTORY.lua",
        script_type = "lua",
    },
    {
        url_path = "style_presets_USER.lua",
        target_path = "Scripts/BRYAN's SCRIPTS/style_presets_USER.lua",
        script_type = "lua",
    },
    
    -- Function files
    {
        url_path = "Vertical FX List Resources/Functions/FX Buttons.lua",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/Functions/FX Buttons.lua",
        script_type = "lua",
    },
    {
        url_path = "Vertical FX List Resources/Functions/Sends.lua",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/Functions/Sends.lua",
        script_type = "lua",
    },
    {
        url_path = "Vertical FX List Resources/Functions/AndaleMonoVertical.ttf",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/Functions/AndaleMonoVertical.ttf",
    },
    
    -- Image assets (required)
    {
        url_path = "Vertical FX List Resources/star.png",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/star.png",
    },
    {
        url_path = "Vertical FX List Resources/starHollow.png",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/starHollow.png",
    },
    {
        url_path = "Vertical FX List Resources/send.png",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/send.png",
    },
    {
        url_path = "Vertical FX List Resources/receive.png",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/receive.png",
    },
    {
        url_path = "Vertical FX List Resources/show.png",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/show.png",
    },
    {
        url_path = "Vertical FX List Resources/hide.png",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/hide.png",
    },
    {
        url_path = "Vertical FX List Resources/link.png",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/link.png",
    },
    {
        url_path = "Vertical FX List Resources/snapshot.png",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/snapshot.png",
    },
    {
        url_path = "Vertical FX List Resources/camera.png",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/camera.png",
    },
    {
        url_path = "Vertical FX List Resources/folder.png",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/folder.png",
    },
    {
        url_path = "Vertical FX List Resources/folder_open.png",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/folder_open.png",
    },
    {
        url_path = "Vertical FX List Resources/settings.png",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/settings.png",
    },
    
    -- Image assets (optional - script has fallbacks)
    {
        url_path = "Vertical FX List Resources/copy.png",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/copy.png",
    },
    {
        url_path = "Vertical FX List Resources/search.png",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/search.png",
    },
    {
        url_path = "Vertical FX List Resources/trash.png",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/trash.png",
    },
    {
        url_path = "Vertical FX List Resources/volume.png",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/volume.png",
    },
    {
        url_path = "Vertical FX List Resources/graph.png",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/graph.png",
    },
    {
        url_path = "Vertical FX List Resources/undo.png",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/undo.png",
    },
    
    -- Other resource files
    {
        url_path = "Vertical FX List Resources/custom_colors.txt",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/custom_colors.txt",
    },
    {
        url_path = "Vertical FX List Resources/fx_category_cache.lua",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/fx_category_cache.lua",
        script_type = "lua",
    },
    {
        url_path = "Vertical FX List Resources/plugin_select_counts.txt",
        target_path = "Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/plugin_select_counts.txt",
    },
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
    if OS:match("Win") then
        -- Windows: escape the output path properly
        local escaped_path = output_path:gsub('"', '\\"')
        cmd = string.format('curl -L -f -s -S -o "%s" "%s" 2>&1', escaped_path, url)
    else
        -- macOS/Linux: use full path to curl, proper quoting
        local escaped_path = output_path:gsub("'", "'\\''")
        cmd = string.format("/usr/bin/curl -L -f -s -S -o '%s' '%s' 2>&1", escaped_path, url)
    end
    
    -- Execute curl (downloads directly to file)
    -- Use shorter timeout for small files (10 seconds should be plenty)
    local result = r.ExecProcess(cmd, 10000) -- 10 second timeout
    
    -- Check for errors in stderr output
    if result and (result:match("curl:") or result:match("404") or result:match("Not Found")) then
        return false, result
    end
    
    -- Check if file was created and has content
    local file = io.open(output_path, "rb")
    if not file then
        return false, "Downloaded file not found: " .. output_path
    end
    
    -- Check file size (should be > 0)
    local size = file:seek("end")
    file:close()
    
    if size == 0 then
        return false, "Downloaded file is empty"
    end
    
    return true, nil
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
    
    local normalized_path = NormalizePath(filepath)
    
    -- Determine section ID based on script type
    -- 0 = Main section (ReaScript)
    local section_id = 0
    
    -- Add script to action list
    -- Parameters: add (true), section (0 = main), path, register (true)
    local success = r.AddRemoveReaScript(true, section_id, normalized_path, true)
    
    if success then
        return true, nil
    else
        return false, "Failed to register script"
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
    
    -- Debug: log the URL being used
    r.ShowConsoleMsg("  URL: " .. full_url .. "\n")
    
    -- Build paths
    local resource_path = GetResourcePath()
    local sep = GetPathSeparator()
    
    -- Download to DOWNLOAD folder first
    local download_folder = resource_path .. sep .. "Scripts" .. sep .. "BRYAN's SCRIPTS" .. sep .. "DOWNLOAD"
    EnsureDirectoryExists(download_folder)
    
    -- Create download path (use filename from target_path)
    local filename = target_path:match("([^/\\]+)$") or url_path:match("([^/\\]+)$")
    local download_path = download_folder .. sep .. filename
    
    -- Download file to DOWNLOAD folder
    if progress_callback then
        progress_callback("Downloading: " .. url_path)
    end
    
    local success, error_msg = DownloadFileToDisk(full_url, download_path)
    
    if not success then
        r.ShowConsoleMsg("  ERROR: " .. (error_msg or "unknown error") .. "\n")
        return false, "Download error: " .. (error_msg or "unknown error") .. " (URL: " .. full_url .. ")"
    end
    
    if progress_callback then
        progress_callback("Downloaded to DOWNLOAD folder")
    end
    
    -- Build final target path
    local full_target = resource_path .. sep .. target_path
    
    -- Copy from DOWNLOAD folder to final location
    if progress_callback then
        progress_callback("Installing: " .. target_path)
    end
    
    local copy_success, copy_error = CopyFile(download_path, full_target)
    if not copy_success then
        return false, "Failed to copy file: " .. (copy_error or "unknown error")
    end
    
    -- Register script if applicable
    script_type = script_type or DetectScriptType(target_path)
    if script_type == "lua" or script_type == "eel" or script_type == "py" then
        if progress_callback then
            progress_callback("Registering: " .. target_path)
        end
        
        local reg_success, reg_error = RegisterScript(full_target, script_type)
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
    
    -- Show summary
    r.ShowConsoleMsg("=== Installation Complete ===\n")
    r.ShowConsoleMsg(string.format("Success: %d\n", #results.success))
    r.ShowConsoleMsg(string.format("Failed: %d\n", #results.failed))
    
    if #results.failed > 0 then
        r.ShowConsoleMsg("\nFailed files:\n")
        for _, fail_info in ipairs(results.failed) do
            r.ShowConsoleMsg(string.format("  - %s: %s\n", fail_info.path, fail_info.error))
        end
    end
    
    -- Show message box summary
    local summary = string.format(
        "Installation Complete\n\n" ..
        "Successfully installed: %d file(s)\n" ..
        "Failed: %d file(s)",
        #results.success,
        #results.failed
    )
    
    if #results.failed > 0 then
        summary = summary .. "\n\nCheck console for details."
    end
    
    local msg_type = (#results.failed == 0) and 0 or 1 -- 0 = OK, 1 = Warning
    r.ShowMessageBox(summary, "BRYAN Script Installer", msg_type)
    
    -- Refresh action list if any scripts were registered
    if #results.success > 0 then
        r.ShowMessageBox(
            "Scripts have been installed and registered.\n\n" ..
            "You can now find them in:\n" ..
            "Actions → Show Action List → ReaScript: Run",
            "Scripts Registered",
            0
        )
    end
    
    -- Reset state
    install_state = {files = {}, current_index = 0, results = {success = {}, failed = {}}, total = 0, started = false}
end

-- Process one file per defer call (non-blocking)
local function ProcessNextFile()
    if not install_state.started or install_state.current_index >= install_state.total then
        ShowInstallSummary()
        return -- Done
    end
    
    local i = install_state.current_index + 1
    install_state.current_index = i
    local file_info = install_state.files[i]
    local results = install_state.results
    
    local repo_key = file_info.repo or next(REPOSITORIES)
    local repo = REPOSITORIES[repo_key]
    local repo_label = string.format("[%s/%s]", repo.user, repo.repo)
    local progress_msg = string.format("[%d/%d] %s %s", i, install_state.total, repo_label, file_info.url_path)
    r.ShowConsoleMsg(progress_msg .. "\n")
    
    local success, error_msg = InstallFile(file_info, function(msg)
        r.ShowConsoleMsg("  " .. msg .. "\n")
    end)
    
    if success then
        table.insert(results.success, file_info.url_path)
        r.ShowConsoleMsg("  ✓ Success\n\n")
    else
        table.insert(results.failed, {path = file_info.url_path, error = error_msg})
        r.ShowConsoleMsg("  ✗ Failed: " .. (error_msg or "unknown error") .. "\n\n")
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
    
    -- Show progress in console
    r.ShowConsoleMsg("\n=== BRYAN Script Installer ===\n")
    
    -- Show repositories being used
    local repos_used = {}
    for _, file_info in ipairs(FILES_TO_INSTALL) do
        local repo_key = file_info.repo or next(REPOSITORIES)
        if not repos_used[repo_key] then
            repos_used[repo_key] = true
            local repo = REPOSITORIES[repo_key]
            r.ShowConsoleMsg(string.format("Repository: %s/%s (%s)\n", repo.user, repo.repo, repo.branch))
        end
    end
    
    r.ShowConsoleMsg(string.format("\nInstalling %d file(s)...\n\n", install_state.total))
    
    -- Start processing files one at a time (non-blocking)
    r.defer(ProcessNextFile)
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

-- Confirm installation
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
else
    r.ShowConsoleMsg("Installation cancelled by user.\n")
end

