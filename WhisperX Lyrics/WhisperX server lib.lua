-- Shared WhisperX model server IPC for REAPER Lua scripts.
-- Persistent Python process keeps ASR/align models in RAM until unload.

local M = {}

local r = reaper

function M.script_paths()
  local info = debug.getinfo(1, "S")
  local lib_path = (info and info.source and info.source:match("^@(.*)$")) or ""
  local lyrics_dir = lib_path:match("^(.*)[/\\][^/\\]-$") or ""
  local scripts_dir = lyrics_dir:match("^(.*)[/\\][^/\\]-$") or ""
  local py = M.join_path(scripts_dir, ".venv_whisperx/bin/python")
  local server_py = M.join_path(lyrics_dir, "reaper_whisperx_server.py")
  local server_dir = M.join_path(scripts_dir, ".whisperx_server")
  return py, server_py, server_dir, lyrics_dir, scripts_dir
end

function M.join_path(a, b)
  if not a or a == "" then
    return b
  end
  if a:sub(-1) == "/" or a:sub(-1) == "\\" then
    return a .. b
  end
  return a .. "/" .. b
end

function M.shell_quote(s)
  s = s:gsub("'", "'\\''")
  return "'" .. s .. "'"
end

function M.file_exists(p)
  local f = io.open(p, "r")
  if f then
    f:close()
    return true
  end
  return false
end

function M.path_exists(p)
  if not p or p == "" then
    return false
  end
  if r.APIExists and r.APIExists("file_exists") then
    return r.file_exists(p)
  end
  return M.file_exists(p)
end

function M.read_all(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

function M.read_json(path)
  local raw = M.read_all(path)
  if not raw or raw == "" then
    return nil
  end
  local ok, data = pcall(function()
    if r.json_decode then
      return r.json_decode(raw)
    end
    -- Minimal fallback for simple flat objects (not used for nested server state).
    return nil
  end)
  if ok and type(data) == "table" then
    return data
  end
  return nil
end

--- Lightweight JSON decode for server state/response (no nested arrays needed).
function M.decode_json_simple(raw)
  if type(raw) ~= "string" or raw == "" then
    return nil
  end
  if r.json_decode then
    local ok, data = pcall(r.json_decode, raw)
    if ok and type(data) == "table" then
      return data
    end
  end
  local t = {}
  for key, val in raw:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do
    t[key] = val
  end
  for key, val in raw:gmatch('"([^"]+)"%s*:%s*(%-?%d+%.?%d*)') do
    t[key] = tonumber(val)
  end
  for key, val in raw:gmatch('"([^"]+)"%s*:%s*(true|false)') do
    t[key] = (val == "true")
  end
  if raw:match('"loaded"%s*:%s*true') then
    t.loaded = true
  elseif raw:match('"loaded"%s*:%s*false') then
    t.loaded = false
  end
  if raw:match('"ok"%s*:%s*true') then
    t.ok = true
  elseif raw:match('"ok"%s*:%s*false') then
    t.ok = false
  end
  if raw:match('"busy"%s*:%s*true') then
    t.busy = true
  elseif raw:match('"busy"%s*:%s*false') then
    t.busy = false
  end
  local phase = raw:match('"phase"%s*:%s*"([^"]+)"')
  if phase then
    t.phase = phase
  end
  local progress_msg = raw:match('"progress_msg"%s*:%s*"([^"]*)"')
  if progress_msg then
    t.progress_msg = progress_msg
  end
  local last_error = raw:match('"last_error"%s*:%s*"([^"]*)"')
  if last_error then
    t.last_error = last_error
  end
  return t
end

function M.read_state()
  local _, _, server_dir = M.script_paths()
  local path = M.join_path(server_dir, "state.json")
  local raw = M.read_all(path)
  if not raw then
    return nil
  end
  return M.decode_json_simple(raw), path
end

function M.read_response()
  local _, _, server_dir = M.script_paths()
  local path = M.join_path(server_dir, "response.json")
  local raw = M.read_all(path)
  if not raw then
    return nil
  end
  return M.decode_json_simple(raw), path
end

function M.pid_alive(pid)
  pid = tonumber(pid)
  if not pid or pid < 1 then
    return false
  end
  local os_str = r.GetOS() or ""
  if os_str:match("Win") then
    local h = io.popen('tasklist /FI "PID eq ' .. tostring(pid) .. '" /NH 2>nul', "r")
    if not h then
      return false
    end
    local out = h:read("*a") or ""
    h:close()
    return out:find(tostring(pid), 1, true) ~= nil
  end
  if os.kill then
    local ok, err, errno = os.kill(pid, 0)
    return ok or errno == 1
  end
  local h = io.popen("kill -0 " .. tostring(pid) .. " 2>/dev/null", "r")
  if not h then
    return false
  end
  local _, _, code = h:close()
  return code == 0
end

function M.server_pid()
  local _, _, server_dir = M.script_paths()
  local raw = M.read_all(M.join_path(server_dir, "pid.txt"))
  if not raw then
    return nil
  end
  return tonumber(raw:match("^%s*(%d+)%s*$"))
end

function M.server_running()
  local pid = M.server_pid()
  if not pid then
    return false
  end
  return M.pid_alive(pid)
end

function M.pipeline_config_from_extstate()
  local SECTION = "BRYAN_WHISPERX"
  local model = r.GetExtState(SECTION, "MODEL")
  if not model or model == "" then
    model = "small"
  end
  local device = r.GetExtState(SECTION, "DEVICE")
  if not device or device == "" then
    device = "cpu"
  end
  device = tostring(device):lower():gsub("%s+", "")
  if device ~= "cpu" and device ~= "cuda" and device ~= "mps" then
    device = "cpu"
  end
  local compute_type = r.GetExtState(SECTION, "COMPUTE_TYPE")
  if not compute_type or compute_type == "" then
    compute_type = "int8"
  end
  compute_type = tostring(compute_type):lower():gsub("%s+", "")
  if compute_type ~= "int8" and compute_type ~= "float16" and compute_type ~= "float32" then
    compute_type = "int8"
  end
  local lang = r.GetExtState(SECTION, "LANGUAGE")
  lang = lang and lang:match("^%s*(.-)%s*$") or ""
  if lang == "" then
    lang = nil
  end
  local interp = r.GetExtState(SECTION, "INTERPOLATE_METHOD")
  local chunk_sz = tonumber(r.GetExtState(SECTION, "CHUNK_SIZE"))
  local vad_m = r.GetExtState(SECTION, "VAD_METHOD")
  vad_m = vad_m and vad_m:lower():gsub("%s+", "") or "pyannote"
  if vad_m ~= "silero" and vad_m ~= "pyannote" then
    vad_m = "pyannote"
  end
  local vad_os = tonumber(r.GetExtState(SECTION, "VAD_ONSET"))
  local vad_off = tonumber(r.GetExtState(SECTION, "VAD_OFFSET"))
  local beam_n = tonumber(r.GetExtState(SECTION, "BEAM_SIZE"))
  local align_m = r.GetExtState(SECTION, "ALIGN_MODEL")
  align_m = align_m and align_m:match("^%s*(.-)%s*$") or ""

  local cfg = {
    model = model,
    device = device,
    compute_type = compute_type,
    batch_size = 8,
    language = lang,
    interpolate_method = (interp and interp ~= "") and interp or "linear",
    vad_method = vad_m,
  }
  if chunk_sz and chunk_sz >= 4 and chunk_sz <= 120 then
    cfg.chunk_size = math.floor(chunk_sz + 0.5)
  end
  if vad_os and vad_os >= 0.01 and vad_os <= 0.99 then
    cfg.vad_onset = vad_os
  end
  if vad_off and vad_off >= 0.01 and vad_off <= 0.99 then
    cfg.vad_offset = vad_off
  end
  if beam_n and beam_n >= 1 and beam_n <= 50 then
    cfg.beam_size = math.floor(beam_n + 0.5)
  end
  if align_m ~= "" then
    cfg.align_model = align_m
  end
  return cfg
end

function M.config_load_signature(cfg)
  local parts = {
    cfg.model or "",
    cfg.device or "",
    cfg.compute_type or "",
    cfg.language or "",
    cfg.vad_method or "",
    tostring(cfg.vad_onset or ""),
    tostring(cfg.vad_offset or ""),
    tostring(cfg.beam_size or ""),
    tostring(cfg.chunk_size or ""),
    cfg.align_model or "",
  }
  return table.concat(parts, "|")
end

function M.loaded_config_matches(cfg)
  local st = M.read_state()
  if not st or not st.loaded then
    return false
  end
  local _, _, server_dir = M.script_paths()
  local raw = M.read_all(M.join_path(server_dir, "state.json"))
  if not raw then
    return false
  end
  local sig = M.config_load_signature(cfg)
  local model = raw:match('"model"%s*:%s*"([^"]+)"')
  local device = raw:match('"device"%s*:%s*"([^"]+)"')
  local compute_type = raw:match('"compute_type"%s*:%s*"([^"]+)"')
  local language = raw:match('"language"%s*:%s*"([^"]+)"')
  if language == "" then
    language = nil
  end
  local vad_method = raw:match('"vad_method"%s*:%s*"([^"]+)"') or "pyannote"
  local vad_onset = raw:match('"vad_onset"%s*:%s*(%-?[%d%.]+)')
  local vad_offset = raw:match('"vad_offset"%s*:%s*(%-?[%d%.]+)')
  local beam_size = raw:match('"beam_size"%s*:%s*(%-?%d+)')
  local chunk_size = raw:match('"chunk_size"%s*:%s*(%-?%d+)')
  local align_model = raw:match('"align_model"%s*:%s*"([^"]+)"')
  local loaded_cfg = {
    model = model or "",
    device = device or "",
    compute_type = compute_type or "",
    language = language,
    vad_method = vad_method,
    vad_onset = vad_onset and tonumber(vad_onset) or nil,
    vad_offset = vad_offset and tonumber(vad_offset) or nil,
    beam_size = beam_size and tonumber(beam_size) or nil,
    chunk_size = chunk_size and tonumber(chunk_size) or nil,
    align_model = align_model or "",
  }
  return M.config_load_signature(loaded_cfg) == sig
end

function M.encode_json(obj)
  if r.json_encode then
    local ok, s = pcall(r.json_encode, obj)
    if ok and type(s) == "string" then
      return s
    end
  end
  local function esc(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r")
    return s
  end
  local function enc_val(v)
    if v == nil then
      return "null"
    end
    if type(v) == "boolean" then
      return v and "true" or "false"
    end
    if type(v) == "number" then
      return tostring(v)
    end
    if type(v) == "string" then
      return '"' .. esc(v) .. '"'
    end
    if type(v) == "table" then
      local is_array = (#v > 0)
      if is_array then
        local items = {}
        for i = 1, #v do
          items[#items + 1] = enc_val(v[i])
        end
        return "[" .. table.concat(items, ",") .. "]"
      end
      local items = {}
      for k, val in pairs(v) do
        if type(k) == "string" then
          items[#items + 1] = '"' .. esc(k) .. '":' .. enc_val(val)
        end
      end
      table.sort(items)
      return "{" .. table.concat(items, ",") .. "}"
    end
    return "null"
  end
  return enc_val(obj)
end

function M.write_request(cmd_obj)
  local _, _, server_dir = M.script_paths()
  os.execute("mkdir -p " .. M.shell_quote(server_dir))
  local tmp = M.join_path(server_dir, "request.tmp")
  local dst = M.join_path(server_dir, "request.json")
  local f = io.open(tmp, "w")
  if not f then
    return false, "could not write request.tmp"
  end
  f:write(M.encode_json(cmd_obj))
  f:close()
  os.remove(dst)
  local ok, err = os.rename(tmp, dst)
  if not ok then
    local rf = io.open(dst, "w")
    if not rf then
      return false, "could not publish request.json"
    end
    rf:write(M.encode_json(cmd_obj))
    rf:close()
    os.remove(tmp)
  end
  return true
end

function M.spawn_server()
  local py, server_py, server_dir = M.script_paths()
  if not M.file_exists(py) then
    return false, "Python venv not found:\n" .. py
  end
  if not M.file_exists(server_py) then
    return false, "Missing server script:\n" .. server_py
  end
  os.execute("mkdir -p " .. M.shell_quote(server_dir))
  local inner = table.concat({
    M.shell_quote(py),
    "-u",
    M.shell_quote(server_py),
    "--server_dir",
    M.shell_quote(server_dir),
  }, " ")
  local wrap = "(" .. inner .. ") >/dev/null 2>&1 &"
  local rc = os.execute("/bin/sh -c " .. M.shell_quote(wrap))
  if rc ~= true and rc ~= 0 and rc ~= nil then
    return false, "failed to spawn server process"
  end
  return true
end

function M.ensure_server(max_wait_s)
  max_wait_s = max_wait_s or 8
  if M.server_running() then
    return true
  end
  local ok, err = M.spawn_server()
  if not ok then
    return false, err
  end
  local t0 = r.time_precise()
  while r.time_precise() - t0 < max_wait_s do
    if M.server_running() then
      return true
    end
    if r.time_precise then
      -- brief yield
    end
  end
  if M.server_running() then
    return true
  end
  return false, "server process did not start (see .whisperx_server/server.log)"
end

function M.wait_for_response(since_ts, timeout_s)
  timeout_s = timeout_s or 3600
  local t0 = r.time_precise()
  local _, _, server_dir = M.script_paths()
  local resp_path = M.join_path(server_dir, "response.json")
  while r.time_precise() - t0 < timeout_s do
    local resp = M.read_response()
    if resp and (not since_ts or (resp.ts and resp.ts >= since_ts) or resp.ok ~= nil) then
      local raw = M.read_all(resp_path)
      if raw and (not since_ts or raw:find('"ts"')) then
        return resp
      end
    end
    -- response.json updates atomically; detect mtime via re-read
    local raw = M.read_all(resp_path)
    if raw and raw ~= "" then
      local resp2 = M.decode_json_simple(raw)
      if resp2 and resp2.ok ~= nil then
        return resp2
      end
    end
  end
  return nil, "timed out waiting for server response"
end

function M.send_command(cmd_obj, timeout_s)
  timeout_s = timeout_s or 3600
  local ok, err = M.ensure_server(10)
  if not ok then
    return false, err
  end
  local _, _, server_dir = M.script_paths()
  local resp_path = M.join_path(server_dir, "response.json")
  pcall(os.remove, resp_path)
  ok, err = M.write_request(cmd_obj)
  if not ok then
    return false, err
  end
  local t0 = r.time_precise()
  while r.time_precise() - t0 < timeout_s do
    local st = M.read_state()
    if st and st.phase == "error" and cmd_obj.cmd == "load" then
      local resp = M.read_response()
      if resp then
        return resp.ok == true, resp.error or st.last_error or "load failed", resp
      end
    end
    local raw = M.read_all(resp_path)
    if raw and raw ~= "" then
      local resp = M.decode_json_simple(raw)
      if resp and resp.ok ~= nil then
        if resp.ok then
          return true, nil, resp
        end
        return false, resp.error or "server command failed", resp
      end
    end
    if cmd_obj.cmd == "transcribe" then
      local done = cmd_obj.job and cmd_obj.job.done_flag
      if done and M.path_exists(done) then
        local code = tonumber(M.read_all(done):match("^%s*(%-?%d+)%s*$"))
        if code ~= nil then
          return code == 0, code ~= 0 and ("exit " .. tostring(code)) or nil, { exit_code = code, ok = code == 0 }
        end
      end
    end
  end
  return false, "timed out waiting for server", nil
end

function M.load_models(timeout_s)
  timeout_s = timeout_s or 7200
  local cfg = M.pipeline_config_from_extstate()
  return M.send_command({ cmd = "load", config = cfg }, timeout_s)
end

--- Queue load without blocking (poll state.json for progress).
function M.submit_load()
  local ok, err = M.ensure_server(10)
  if not ok then
    return false, err
  end
  local cfg = M.pipeline_config_from_extstate()
  ok, err = M.write_request({ cmd = "load", config = cfg })
  if not ok then
    return false, err
  end
  return true
end

function M.load_in_progress()
  local st = M.read_state()
  if not st then
    return false
  end
  return st.phase == "loading"
end

function M.load_complete()
  local st = M.read_state()
  return st and st.loaded and st.phase == "ready"
end

function M.unload_models(timeout_s)
  timeout_s = timeout_s or 120
  if not M.server_running() then
    return true
  end
  return M.send_command({ cmd = "unload" }, timeout_s)
end

function M.models_ready_for_dictation()
  if not M.server_running() then
    return false
  end
  local st = M.read_state()
  if not st or not st.loaded then
    return false
  end
  if st.busy or st.phase == "busy" or st.phase == "loading" then
    return false
  end
  local cfg = M.pipeline_config_from_extstate()
  return M.loaded_config_matches(cfg)
end

function M.transcribe_via_server(job_fields, timeout_s)
  timeout_s = timeout_s or 4 * 3600
  local cfg = M.pipeline_config_from_extstate()
  return M.send_command({ cmd = "transcribe", config = cfg, job = job_fields }, timeout_s)
end

--- Queue transcribe on the server without blocking (poll done_flag / progress_file separately).
function M.submit_transcribe(job_fields)
  local ok, err = M.ensure_server(10)
  if not ok then
    return false, err
  end
  if job_fields.done_flag and M.path_exists(job_fields.done_flag) then
    pcall(os.remove, job_fields.done_flag)
  end
  local cfg = M.pipeline_config_from_extstate()
  ok, err = M.write_request({ cmd = "transcribe", config = cfg, job = job_fields })
  if not ok then
    return false, err
  end
  return true
end

function M.status_text()
  if not M.server_running() then
    return "Server not running — models not loaded"
  end
  local st = M.read_state()
  if not st then
    return "Server starting…"
  end
  if st.phase == "loading" then
    return string.format("Loading… %s%% — %s", tostring(st.progress_pct or 0), st.progress_msg or "")
  end
  if st.busy or st.phase == "busy" then
    return string.format("Transcribing… %s%% — %s", tostring(st.progress_pct or 0), st.progress_msg or "")
  end
  if st.loaded then
    local cfg = M.pipeline_config_from_extstate()
    if M.loaded_config_matches(cfg) then
      return "Models loaded — ready for fast dictation"
    end
    return "Models loaded but settings changed — unload and reload to match current settings"
  end
  if st.phase == "idle" then
    return "Server running — models not loaded"
  end
  return st.progress_msg or st.phase or "unknown"
end

return M
