# OAuth Configuration Guide

This script now supports secure OAuth credential management through environment variables or a configuration file.

## Setup Options

### Option 1: Environment Variables (Recommended - Most Secure)

Set the following environment variables before running REAPER:

**macOS/Linux:**
```bash
export GOOGLE_OAUTH_CLIENT_ID="your-client-id-here"
export GOOGLE_OAUTH_CLIENT_SECRET="your-client-secret-here"
```

**Windows:**
```cmd
set GOOGLE_OAUTH_CLIENT_ID=your-client-id-here
set GOOGLE_OAUTH_CLIENT_SECRET=your-client-secret-here
```

### Option 2: Configuration File

1. Copy `oauth_config.example.lua` to `oauth_config.lua`:
   ```bash
   cp oauth_config.example.lua oauth_config.lua
   ```

2. Edit `oauth_config.lua` and replace the placeholder values with your actual credentials:
   ```lua
   return {
     client_id = "your-actual-client-id",
     client_secret = "your-actual-client-secret"
   }
   ```

## Security Notes

- **Never commit `oauth_config.lua` to version control**
- Add `oauth_config.lua` to your `.gitignore` file
- Environment variables are preferred as they don't leave credentials in files
- The config file is stored in the same directory as the script

## Usage in Code

The script provides helper functions to access OAuth credentials:

```lua
local clientId = GetOAuthClientId()
local clientSecret = GetOAuthClientSecret()
```

These functions automatically load from environment variables first, then fall back to the config file if needed.

