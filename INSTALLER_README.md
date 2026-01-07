# BRYAN Script Installer - Usage Guide

## Overview
This is a custom ReaPack alternative that downloads and installs scripts, JSFX, and assets directly from your GitHub repositories. It supports multiple repositories and automatically registers scripts in REAPER's Action List.

## Setup Instructions

### 1. Configure Your GitHub Repositories

Edit `BRYAN Script Installer.lua` and define your repositories in the `REPOSITORIES` table:

```lua
local REPOSITORIES = {
    -- Default/main repository
    main = {
        user = "BryanChi",      -- GitHub username
        repo = "MyRepo",         -- Repository name
        branch = "main"          -- Branch name (main, master, etc.)
    },
    
    -- Add more repositories as needed
    scripts = {
        user = "BryanChi",
        repo = "MyScriptsRepo",
        branch = "main"
    },
    effects = {
        user = "BryanChi",
        repo = "MyEffectsRepo",
        branch = "main"
    },
}
```

Each repository has a unique key (like `main`, `scripts`, `effects`) that you'll reference when adding files.

### 2. Add Files to Install

In the `FILES_TO_INSTALL` table, add entries for each file you want to install:

```lua
local FILES_TO_INSTALL = {
    -- Scripts from main repo
    {url_path = "Scripts/MyTool.lua", target_path = "Scripts/BRYAN's SCRIPTS/MyTool.lua", script_type = "lua", repo = "main"},
    
    -- Scripts from different repo
    {url_path = "Scripts/AnotherScript.lua", target_path = "Scripts/BRYAN's SCRIPTS/AnotherScript.lua", script_type = "lua", repo = "scripts"},
    
    -- JSFX from main repo
    {url_path = "Effects/MyEffect.jsfx", target_path = "Effects/MyEffect.jsfx", script_type = "jsfx", repo = "main"},
    
    -- Assets (images, fonts, etc.) - repo is optional, defaults to first repo
    {url_path = "Assets/logo.png", target_path = "Scripts/BRYAN's SCRIPTS/logo.png", script_type = "asset"},
}
```

**Parameters:**
- `url_path`: Path relative to repo root (how it appears in GitHub)
- `target_path`: Path relative to REAPER resource folder (where it should be installed)
- `script_type`: Optional. Can be "lua", "eel", "py", "jsfx", or "asset". If omitted, auto-detected from file extension.
- `repo`: Optional. Repository key from `REPOSITORIES` table. If omitted, uses the first repository defined.

### 3. GitHub Repository Structure

Your GitHub repo should be organized like this:

```
MyRepo/
├── Scripts/
│   ├── MyTool.lua
│   └── AnotherScript.lua
├── Effects/
│   └── MyEffect.jsfx
└── Assets/
    └── logo.png
```

### 4. Make Repository Public (or use GitHub token)

For the installer to work, your repository must be:
- **Public**, OR
- **Private** with proper authentication (requires additional setup)

The installer uses GitHub's raw file URLs:
`https://raw.githubusercontent.com/USER/REPO/BRANCH/path/to/file`

## Usage

### For You (Developer)

1. Upload your files to GitHub
2. Update `FILES_TO_INSTALL` in the installer script
3. Upload the installer script itself to GitHub
4. Share the installer script with your users

### For Your Users

1. Download `BRYAN Script Installer.lua` from your GitHub repo
2. Place it in their REAPER Scripts folder
3. Run it from REAPER: Actions → Show Action List → ReaScript: Run → Select the installer
4. Confirm installation when prompted
5. Check console for progress and results
6. Scripts will automatically appear in Action List

## Features

- ✅ **Multiple Repository Support** - Install files from different GitHub repositories in one go
- ✅ Downloads files from GitHub raw URLs
- ✅ Creates directories automatically
- ✅ Installs scripts, JSFX, and assets
- ✅ Automatically registers scripts in Action List
- ✅ Shows progress in console with repository labels
- ✅ Error handling and reporting
- ✅ Works on Windows, macOS, and Linux

## Requirements

- **curl** must be installed on the system
  - Windows: Download from https://curl.se/windows/
  - macOS/Linux: Usually pre-installed

## REAPER Folder Structure

Files are installed to these locations relative to REAPER resource folder:

- **Scripts**: `Scripts/` or `Scripts/BRYAN's SCRIPTS/`
- **JSFX**: `Effects/`
- **FX Chains**: `Presets/`
- **Assets**: Anywhere you specify (usually in Scripts subfolder)

## Troubleshooting

### "curl is not available"
- Install curl on your system
- Windows: Download from https://curl.se/windows/
- macOS/Linux: Install via package manager if missing

### "Failed to download" or "404"
- Check that the file path in `url_path` matches your GitHub repo structure
- Verify the repository is public (or set up authentication)
- Check that the branch name is correct
- If using multiple repos, verify the `repo` key in the file entry matches a key in `REPOSITORIES` table

### "Failed to register script"
- File was installed but not registered in Action List
- Check console for specific error
- Try manually adding script: Actions → Show Action List → ReaScript: New/Load

### Scripts don't appear in Action List
- Make sure script type is correct ("lua", "eel", or "py")
- Check that file was written successfully
- Try refreshing Action List or restarting REAPER

## Multiple Repositories Example

Here's a complete example using multiple repositories:

```lua
local REPOSITORIES = {
    main = {
        user = "BryanChi",
        repo = "MyMainScripts",
        branch = "main"
    },
    effects = {
        user = "BryanChi",
        repo = "MyJSFX",
        branch = "main"
    },
    assets = {
        user = "BryanChi",
        repo = "MyAssets",
        branch = "main"
    },
}

local FILES_TO_INSTALL = {
    -- From main repo
    {url_path = "Scripts/Tool1.lua", target_path = "Scripts/BRYAN's SCRIPTS/Tool1.lua", repo = "main"},
    {url_path = "Scripts/Tool2.lua", target_path = "Scripts/BRYAN's SCRIPTS/Tool2.lua", repo = "main"},
    
    -- From effects repo
    {url_path = "Effects/Reverb.jsfx", target_path = "Effects/Reverb.jsfx", repo = "effects"},
    {url_path = "Effects/Delay.jsfx", target_path = "Effects/Delay.jsfx", repo = "effects"},
    
    -- From assets repo
    {url_path = "Images/logo.png", target_path = "Scripts/BRYAN's SCRIPTS/logo.png", repo = "assets"},
    
    -- No repo specified - uses first repo (main)
    {url_path = "Scripts/DefaultTool.lua", target_path = "Scripts/BRYAN's SCRIPTS/DefaultTool.lua"},
}
```

## Advanced: Version Checking

To add version checking, you could:

1. Add a version file to each repo (e.g., `version.txt`)
2. Download and compare versions before installing
3. Only install if newer version available

Example:
```lua
local function CheckVersion(repo_key)
    local repo_base = GetRepoRawBase(repo_key)
    local version_url = repo_base .. "/version.txt"
    local remote_version = DownloadFile(version_url)
    -- Compare with local version
end
```

## Advanced: Update Functionality

To add update functionality:

1. Store installed file paths and versions locally
2. Check GitHub for newer versions
3. Only download changed files
4. Optionally backup old files before updating

## Notes

- Files are overwritten if they already exist
- Scripts are automatically registered (no manual Action List addition needed)
- JSFX files appear automatically in FX browser
- The installer shows progress in REAPER console
- All operations are logged to console for debugging

