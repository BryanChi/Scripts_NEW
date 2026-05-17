-- @description WhisperX dictation: transcribe selected item(s) (JSON + in-project lyrics)
-- @version 1.15
-- @author Bryan
-- @about
--   Runs WhisperX via ../.venv_whisperx, writes .whisperx.json plus sidecars
--   <same_base>.words.tsv and <same_base>.plain.txt next to the media file (same_base
--   is the path with .whisperx.json stripped). Mirrors ASCII _whisperx_last.* copies
--   and _whisperx_run.log in the project folder. On macOS/Linux uses io.popen instead
--   of ExecProcess so subprocess output and completion are reliable.
--   On macOS/Linux (USE_BACKGROUND=1, default): spawns Python detached and polls with
--   reaper.defer + a small gfx progress window so REAPER stays responsive. Windows always
--   uses the blocking subprocess path.
--   Timing / quality extstate BRYAN_WHISPERX:
--   LANGUAGE (e.g. ja) — force language for ASR + alignment; avoids detector drift.
--   MODEL — default large-v2 (override with small/medium/etc.; slower on CPU).
--   CHUNK_SIZE — optional seconds for Whisper VAD merge (empty = WhisperX default ~30). Smaller (e.g. 12–18) often helps JA lyrics:
--     shorter transcript segments ⇒ wav2vec aligns fewer morae per segment (see WhisperX whisperx/asr.py transcribe chunk_size).
--   VAD_METHOD — pyannote | silero (silero can avoid extra HF pyannote setup).
--   VAD_ONSET / VAD_OFFSET — optional floats (see WhisperX vad_options defaults ~0.5 / 0.363).
--   BEAM_SIZE — optional decoder beam for faster-whisper (WhisperX default 5).
--   ALIGN_MODEL — optional Hugging Face wav2vec2 id for forced alignment (overrides language default).
--   MARKER_AT — start (default) | mid | end — take marker time inside each word interval.
--   INTERPOLATE_METHOD — WhisperX align gap fill (default linear in Python; try nearest).
--   Plus TIMEOUT_MS, USE_BACKGROUND, DEVICE, COMPUTE_TYPE, WRITE_ITEM_NOTES, WRITE_TAKE_MARKERS,
--   MAX_WORD_MARKERS. Optional GUI: “WhisperX dictation settings (ReaImGui).lua”.
--   When writing take markers, all existing markers on that take are removed first; each word is one plain-named marker.

local r = reaper

local LOG_PREFIX = "[WhisperX dictation] "

local function log_line(msg)
  r.ShowConsoleMsg(LOG_PREFIX .. tostring(msg) .. "\n")
end

local function script_path()
  local info = debug.getinfo(1, "S")
  if not info or not info.source then return "" end
  local p = info.source:match("^@(.*)$") or ""
  return p
end

local function dirname(p)
  if not p or p == "" then return "" end
  local d = p:match("^(.*)[/\\][^/\\]-$")
  return d or ""
end

local function join_path(a, b)
  if not a or a == "" then return b end
  if a:sub(-1) == "/" or a:sub(-1) == "\\" then
    return a .. b
  end
  return a .. "/" .. b
end

local function shell_quote(s)
  s = s:gsub("'", "'\\''")
  return "'" .. s .. "'"
end

local function get_paths()
  local sp = script_path()
  local lyrics_dir = dirname(sp)
  local scripts_dir = dirname(lyrics_dir)
  local py = join_path(scripts_dir, ".venv_whisperx/bin/python")
  local transcribe_py = join_path(lyrics_dir, "reaper_whisperx_transcribe.py")
  return py, transcribe_py, lyrics_dir
end

local function file_exists_io(p)
  local f = io.open(p, "r")
  if f then f:close() return true end
  return false
end

local function path_exists(p)
  if not p or p == "" then return false end
  if r.APIExists and r.APIExists("file_exists") then
    return r.file_exists(p)
  end
  return file_exists_io(p)
end

-- GetMediaSourceFileName: Lua may return just the path, or (retval, path); accept either.
local function filename_from_source(src)
  local a, b = r.GetMediaSourceFileName(src, "")
  if type(b) == "string" and b ~= "" then
    return b
  end
  if type(a) == "string" and a ~= "" then
    return a
  end
  a, b = r.GetMediaSourceFileName(src)
  if type(b) == "string" and b ~= "" then
    return b
  end
  if type(a) == "string" and a ~= "" then
    return a
  end
  return nil
end

local function resolve_underlying_media_path(src)
  local depth = 0
  while src and depth < 64 do
    local fn = filename_from_source(src)
    if fn and fn ~= "" then
      return fn
    end
    if not r.GetMediaSourceParent then
      break
    end
    src = r.GetMediaSourceParent(src)
    depth = depth + 1
  end
  return nil
end

local function project_file_directory()
  local _, projfn = r.EnumProjects(-1, "")
  if projfn and projfn ~= "" then
    return dirname(projfn)
  end
  return ""
end

local function absolutize_path(path)
  if not path or path == "" then
    return nil
  end
  if path:sub(1, 1) == "/" then
    return path
  end
  if path:match("^%a:[/\\]") then
    return path
  end
  local pd = project_file_directory()
  if pd and pd ~= "" then
    return join_path(pd, path)
  end
  return path
end

local function default_output_json(media_path)
  local base = media_path:match("^(.*)%.[^%.\\/]+$") or (media_path .. "_transcript")
  return base .. ".whisperx.json"
end

-- foo.whisperx.json -> foo.words.tsv (must match Python _sidecar_paths)
local function sidecar_paths_from_whisperx_json(json_path)
  local suf = ".whisperx.json"
  if #json_path >= #suf and json_path:sub(-#suf) == suf then
    local stem = json_path:sub(1, #json_path - #suf)
    return stem .. ".words.tsv", stem .. ".plain.txt"
  end
  local base = json_path:match("^(.*)%.[^%.\\/]+$") or json_path
  return base .. ".words.tsv", base .. ".plain.txt"
end

--- Each entry: { item, take, media_path, out_json, out_tsv, out_plain, inner_cmd }
--- Skips invalid selected items (logged); returns nil, err if nothing usable.
local function collect_selected_dictation_jobs(inner_cmd_builder)
  local n = r.CountSelectedMediaItems(0)
  if n < 1 then
    return nil, "Select at least one media item with an audio take."
  end
  local jobs = {}
  local skips = {}
  local seen_paths = {}
  for i = 0, n - 1 do
    local item = r.GetSelectedMediaItem(0, i)
    local why = nil
    local take = item and r.GetActiveTake(item)
    if not item then
      why = "no item"
    elseif not take then
      why = "no active take"
    else
      local src = r.GetMediaItemTake_Source(take)
      if not src then
        why = "take has no PCM source"
      else
        local path = resolve_underlying_media_path(src)
        if not path or path == "" then
          why = "no file path (render/freeze to WAV first)"
        else
          path = absolutize_path(path)
          local lk = path:lower()
          if seen_paths[lk] then
            why = "duplicate media path (same file as another selected item)"
          else
            seen_paths[lk] = true
            local out_json = default_output_json(path)
            local out_tsv, out_plain = sidecar_paths_from_whisperx_json(out_json)
            local inner_cmd = inner_cmd_builder(path, out_json)
            jobs[#jobs + 1] = {
              item = item,
              take = take,
              media_path = path,
              out_json = out_json,
              out_tsv = out_tsv,
              out_plain = out_plain,
              inner_cmd = inner_cmd,
            }
          end
        end
      end
    end
    if why then
      skips[#skips + 1] = "Track item #" .. tostring(i + 1) .. ": " .. why
    end
  end
  if #jobs < 1 then
    local detail = (#skips > 0) and table.concat(skips, "\n") or "Unknown error."
    return nil, "No usable media items in selection.\n\n" .. detail
  end
  if #skips > 0 then
    log_line("WhisperX batch: skipping " .. tostring(#skips) .. " selected row(s):\n" .. table.concat(skips, "\n"))
  end
  log_line("WhisperX batch: " .. tostring(#jobs) .. " item(s) queued (processed one after another).")
  return jobs, nil
end

local function parse_timeout_ms()
  local s = r.GetExtState("BRYAN_WHISPERX", "TIMEOUT_MS")
  if not s or s == "" then
    return 0
  end
  local n = tonumber(s)
  if not n or n < 0 then
    return 0
  end
  return math.floor(n)
end

local function ext_flag(key, default_true)
  local s = r.GetExtState("BRYAN_WHISPERX", key)
  if s == nil or s == "" then
    return default_true
  end
  local sl = s:lower()
  if s == "0" or sl == "false" or sl == "off" or sl == "no" then
    return false
  end
  return true
end

local function ext_int(key, default_v)
  local s = r.GetExtState("BRYAN_WHISPERX", key)
  local n = tonumber(s)
  if n and n > 0 then
    return math.floor(n)
  end
  return default_v
end

-- Take marker source time from WhisperX word [st, en] (seconds in source file).
local function marker_srcpos_for_word(st, en)
  if not st then
    return nil
  end
  if not en or en < st then
    return st
  end
  local at = r.GetExtState("BRYAN_WHISPERX", "MARKER_AT")
  if not at then
    at = ""
  end
  at = at:lower():gsub("%s+", "")
  if at == "start" or at == "begin" then
    return st
  end
  if at == "mid" or at == "middle" or at == "center" or at == "centre" then
    return (st + en) * 0.5
  end
  if at == "end" then
    return en
  end
  -- default: word onset (empty extstate); avoids markers feeling consistently late vs mid/end.
  return st
end

local function wrap_exec_command(inner)
  local os_str = r.GetOS() or ""
  if os_str:match("Win") then
    return inner
  end
  return "/bin/sh -c " .. shell_quote(inner .. " 2>&1")
end

-- REAPER ExecProcess often returns only "0\n" here with no stdout; io.popen captures reliably (macOS/Linux).
local function run_whisperx_shell(inner_cmd, timeout_ms)
  local os_str = r.GetOS() or ""
  if not os_str:match("Win") and io.popen then
    local sh_cmd = "/bin/sh -c " .. shell_quote(inner_cmd .. " 2>&1")
    local h = io.popen(sh_cmd, "r")
    if not h then
      log_line("io.popen failed; falling back to reaper.ExecProcess")
      return r.ExecProcess(wrap_exec_command(inner_cmd), timeout_ms)
    end
    local body = h:read("*a") or ""
    local a, b, c = h:close()
    local exit_code = 1
    if a == true then
      exit_code = 0
    elseif type(a) == "number" and a == 0 then
      exit_code = 0
    elseif a == nil and b == "exit" and type(c) == "number" then
      exit_code = c
    elseif a == nil and type(c) == "number" then
      exit_code = c
    end
    log_line("io.popen close: a=" .. tostring(a) .. " b=" .. tostring(b) .. " c=" .. tostring(c))
    return tostring(exit_code) .. "\n" .. body
  end
  return r.ExecProcess(wrap_exec_command(inner_cmd), timeout_ms)
end

--- Remove every take marker on this take before writing word timings (plain marker names, no wx| prefix).
local function wipe_all_take_markers(take)
  if not take or not r.GetNumTakeMarkers or not r.DeleteTakeMarker then
    return
  end
  local n = r.GetNumTakeMarkers(take)
  for i = n - 1, 0, -1 do
    r.DeleteTakeMarker(take, i)
  end
end

local function read_all_utf8(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

--- Lua #s and s:sub(i,j) count bytes. Truncating Japanese (3-byte UTF-8) at a byte boundary
--- leaves invalid tails (e.g. E3 81) — ReaImGui then shows mojibake or blank glyphs.
local function utf8_safe_truncate_bytes(s, max_bytes)
  if type(s) ~= "string" or max_bytes <= 0 then
    return ""
  end
  if #s <= max_bytes then
    return s
  end
  s = s:sub(1, max_bytes)
  if utf8 and utf8.len then
    while #s > 0 do
      local ok = pcall(utf8.len, s)
      if ok then
        return s
      end
      s = s:sub(1, -2)
    end
    return ""
  end
  while #s > 0 do
    local b = s:byte(#s)
    if b >= 0x80 and b < 0xC0 then
      s = s:sub(1, -2)
    elseif b >= 0xC0 and b < 0xE0 then
      if #s < 2 then
        s = s:sub(1, -2)
      else
        return s
      end
    elseif b >= 0xE0 and b < 0xF0 then
      if #s < 3 then
        s = s:sub(1, -2)
      else
        return s
      end
    elseif b >= 0xF0 and b < 0xF8 then
      if #s < 4 then
        s = s:sub(1, -2)
      else
        return s
      end
    else
      return s
    end
  end
  return ""
end

local function apply_transcript_to_item(item, take, tsv_path, plain_path)
  if not item or not take then
    return
  end

  wipe_all_take_markers(take)

  local plain_text = ""
  if plain_path and path_exists(plain_path) then
    plain_text = read_all_utf8(plain_path) or ""
  end

  if plain_text == "" and tsv_path and path_exists(tsv_path) then
    local words = {}
    local f = io.open(tsv_path, "rb")
    if f then
      for line in f:lines() do
        local w = line:match("^[^\t]+\t[^\t]+\t(.+)$")
        if w then
          words[#words + 1] = w
        end
      end
      f:close()
      plain_text = table.concat(words, " ")
    end
  end

  if plain_text ~= "" and ext_flag("WRITE_ITEM_NOTES", true) and r.GetSetMediaItemInfo_String then
    local ok = r.GetSetMediaItemInfo_String(item, "P_NOTES", plain_text, true)
    if not ok then
      r.GetSetMediaItemInfo_String(item, "NOTES", plain_text, true)
    end
  end

  if not ext_flag("WRITE_TAKE_MARKERS", true) or not tsv_path or not path_exists(tsv_path) or not r.SetTakeMarker then
    r.UpdateArrange()
    return
  end

  log_line(
    "take markers: MARKER_AT="
      .. tostring(r.GetExtState("BRYAN_WHISPERX", "MARKER_AT"))
      .. " (empty=start; start|mid|end)"
  )

  local max_m = ext_int("MAX_WORD_MARKERS", 1500)
  local count = 0
  local f = io.open(tsv_path, "rb")
  if f then
    for line in f:lines() do
      if count >= max_m then
        log_line("take markers capped at " .. tostring(max_m) .. " (BRYAN_WHISPERX MAX_WORD_MARKERS)")
        break
      end
      local st_s, en_s, word = line:match("^([^\t]+)\t([^\t]+)\t(.*)$")
      if st_s and en_s and word then
        local st = tonumber(st_s)
        local en = tonumber(en_s)
        local pos = marker_srcpos_for_word(st, en)
        word = word:gsub("[\r\n]", " ")
        word = word:gsub("|", "\239\189\156")
        if #word > 180 then
          word = utf8_safe_truncate_bytes(word, 180) .. "…"
        end
        if pos then
          r.SetTakeMarker(take, -1, word, pos)
          count = count + 1
        end
      end
    end
    f:close()
  end

  r.UpdateArrange()
end

-- Background job (macOS/Linux): defer polls --done_flag; Python writes --progress_file.
local WX_job = nil

local function wx_read_progress_lines(path)
  local f = io.open(path, "rb")
  if not f then
    return 0, ""
  end
  local l1 = f:read("*l") or "0"
  local l2 = f:read("*l") or ""
  f:close()
  l1 = (l1:gsub("%s+", "") or "0")
  local pct = tonumber(l1) or 0
  if pct < 0 then
    pct = 0
  elseif pct > 100 then
    pct = 100
  end
  l2 = (l2:gsub("[\r\n]", "") or "")
  return pct, l2
end

local function wx_read_done_code(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local s = f:read("*a") or ""
  f:close()
  return tonumber(s:match("^%s*(%-?%d+)%s*$"))
end

local function whisperx_spawn_unix_detached(inner_cmd, done_path)
  if path_exists(done_path) then
    pcall(os.remove, done_path)
  end
  local wrap = "(" .. inner_cmd .. ") >/dev/null 2>&1"
  local line = "/bin/sh -c " .. shell_quote(wrap) .. " &"
  local rc = os.execute(line)
  return rc == true or rc == 0 or rc == nil
end

local function whisperx_ptr_item_take_ok(item, take)
  if r.ValidatePtr then
    return r.ValidatePtr(item, "MediaItem*") and r.ValidatePtr(take, "MediaTake*")
  end
  return item ~= nil and take ~= nil
end

local function whisperx_finalize(st, exit_code, stdout, finalize_opts)
  finalize_opts = finalize_opts or {}
  local suppress_success_mb = finalize_opts.suppress_success_mb
  local batch_index = finalize_opts.batch_index
  local batch_total = finalize_opts.batch_total

  local dbg_txt = read_all_utf8(st.debug_log)
  if dbg_txt and dbg_txt ~= "" then
    local cap = 48000
    if #dbg_txt > cap then
      dbg_txt = dbg_txt:sub(1, cap) .. "\n… (_whisperx_run.log truncated for console)\n"
    end
    log_line("---- _whisperx_run.log ----\n" .. dbg_txt)
  else
    log_line("no debug log at " .. st.debug_log .. " (Python may not have started)")
  end

  if exit_code ~= 0 then
    log_line("FAILED exit " .. tostring(exit_code))
    r.Undo_EndBlock("WhisperX dictation (failed)", -1)
    local err_detail = (stdout and stdout ~= "") and stdout:sub(1, 4000) or ""
    if err_detail == "" and dbg_txt and dbg_txt ~= "" then
      err_detail = dbg_txt:sub(math.max(1, #dbg_txt - 4000))
    end
    if err_detail == "" then
      err_detail = "See log:\n" .. st.debug_log
    end
    r.MB("WhisperX failed (exit " .. tostring(exit_code) .. ").\n\n" .. err_detail, "WhisperX dictation", 0)
    return false
  end

  if stdout and stdout ~= "" then
    local preview = stdout
    if #preview > 12000 then
      preview = preview:sub(1, 12000) .. "\n… (truncated)\n"
    end
    log_line("---- subprocess output ----\n" .. preview)
  end

  local json_ok = path_exists(st.out_json)
  local tsv_ok = path_exists(st.out_tsv)
  local plain_ok = path_exists(st.out_plain)
  local m_json_ok = path_exists(st.mirror_json)
  local m_tsv_ok = path_exists(st.mirror_tsv)
  local m_plain_ok = path_exists(st.mirror_plain)

  log_line("after run: json=" .. tostring(json_ok) .. " tsv=" .. tostring(tsv_ok) .. " plain=" .. tostring(plain_ok))
  log_line(
    "mirror: json=" .. tostring(m_json_ok) .. " tsv=" .. tostring(m_tsv_ok) .. " plain=" .. tostring(m_plain_ok)
  )

  local use_json = json_ok and st.out_json or (m_json_ok and st.mirror_json or nil)
  local use_tsv = tsv_ok and st.out_tsv or (m_tsv_ok and st.mirror_tsv or nil)
  local use_plain = plain_ok and st.out_plain or (m_plain_ok and st.mirror_plain or nil)

  if not use_tsv then
    log_line("ERROR: words TSV missing at both primary and mirror paths")
    r.Undo_EndBlock("WhisperX dictation (no output files)", -1)
    r.MB(
      "WhisperX reported success but no .words.tsv was found.\n\n"
        .. "Primary:\n"
        .. st.out_tsv
        .. "\n\nMirror:\n"
        .. st.mirror_tsv
        .. "\n\nOpen the REAPER console and/or this log:\n"
        .. st.debug_log,
      "WhisperX dictation",
      0
    )
    return false
  end

  if not whisperx_ptr_item_take_ok(st.item, st.take) then
    log_line("item/take no longer valid after run; skipping apply")
    r.Undo_EndBlock("WhisperX dictation (stale selection)", -1)
    r.MB(
      "The original media item is no longer selected or was removed before transcription finished.\n\n"
        .. "Output is on disk:\n"
        .. use_tsv,
      "WhisperX dictation",
      0
    )
    return false
  end

  apply_transcript_to_item(st.item, st.take, use_tsv, use_plain)

  local undo_label = "WhisperX dictation"
  if batch_total and batch_total > 1 and batch_index then
    undo_label = "WhisperX dictation (" .. tostring(batch_index) .. "/" .. tostring(batch_total) .. ")"
  end
  r.Undo_EndBlock(undo_label, -1)

  if not suppress_success_mb then
    local msg = "Transcript applied to item notes + take markers (one marker per word).\n\nJSON:\n"
      .. (use_json or st.out_json)
      .. "\n\nWords TSV:\n"
      .. use_tsv
      .. "\n\nAlso check mirror copies:\n"
      .. st.mirror_json
    if batch_total and batch_total > 1 and batch_index then
      msg = "Batch item " .. tostring(batch_index) .. " of " .. tostring(batch_total) .. ".\n\n" .. msg
    end
    r.MB(msg, "WhisperX dictation", 0)
  end
  return true
end

local function wx_job_current_state(j)
  local job = j.batch_jobs[j.batch_cur]
  return {
    item = job.item,
    take = job.take,
    out_json = job.out_json,
    out_tsv = job.out_tsv,
    out_plain = job.out_plain,
    mirror_json = j.mirror_json,
    mirror_tsv = j.mirror_tsv,
    mirror_plain = j.mirror_plain,
    debug_log = j.debug_log,
  }
end

local function wx_poll()
  local j = WX_job
  if not j then
    return
  end

  local now = r.time_precise()
  if now - j.t0 > j.max_wait then
    WX_job = nil
    if j.gfx_on and gfx and gfx.quit then
      gfx.quit()
    end
    r.Undo_EndBlock("WhisperX dictation (timeout)", -1)
    r.MB(
      "WhisperX exceeded max wait ("
        .. tostring(math.floor(j.max_wait / 60))
        .. " min).\nThe Python process may still be running.\n\nLog:\n"
        .. j.debug_log,
      "WhisperX dictation",
      0
    )
    return
  end

  local code = wx_read_done_code(j.done_flag)
  if code == nil then
    if j.gfx_on and gfx then
      local ch = gfx.getchar and gfx.getchar() or 0
      if ch == -1 then
        j.gfx_on = false
        log_line("progress window closed; still waiting for WhisperX (see console / log)…")
      else
        local pct, msg = wx_read_progress_lines(j.progress_file)
        -- gfx.clear is a color value in REAPER Lua, not a function (see gfx.update).
        gfx.clear = 0x202020
        gfx.set(70, 70, 70, 255)
        gfx.rect(16, 38, 388, 16, 1)
        gfx.set(55, 130, 220, 255)
        gfx.rect(16, 38, math.floor(math.max(0, 388 * pct / 100)), 16, 1)
        gfx.set(230, 230, 230, 255)
        if gfx.setfont then
          gfx.setfont(1, "Arial", 15)
        end
        gfx.x = 16
        gfx.y = 10
        if gfx.drawstr then
          local bt = j.batch_total or 1
          local bc = j.batch_cur or 1
          gfx.drawstr(
            "WhisperX [" .. tostring(bc) .. "/" .. tostring(bt) .. "]  " .. tostring(pct) .. "%  " .. msg
          )
        end
        gfx.update()
      end
    end
    r.defer(wx_poll)
    return
  end

  local st = wx_job_current_state(j)
  local bt = j.batch_total or 1
  local bc = j.batch_cur or 1
  local ok = whisperx_finalize(st, code, "", {
    batch_index = bc,
    batch_total = bt,
    suppress_success_mb = bc < bt,
  })
  if not ok then
    if j.gfx_on and gfx and gfx.quit then
      gfx.quit()
    end
    WX_job = nil
    return
  end

  if bc < bt then
    j.batch_cur = bc + 1
    local next_job = j.batch_jobs[j.batch_cur]
    if path_exists(j.done_flag) then
      pcall(os.remove, j.done_flag)
    end
    r.Undo_BeginBlock()
    if not whisperx_spawn_unix_detached(next_job.inner_cmd, j.done_flag) then
      r.Undo_EndBlock("WhisperX dictation (failed)", -1)
      if j.gfx_on and gfx and gfx.quit then
        gfx.quit()
      end
      WX_job = nil
      r.MB("Could not start the next WhisperX job in batch.", "WhisperX dictation", 0)
      return
    end
    j.t0 = r.time_precise()
    WX_job = j
    r.defer(wx_poll)
    return
  end

  if j.gfx_on and gfx and gfx.quit then
    gfx.quit()
  end
  WX_job = nil
end

local function main()
  if WX_job then
    r.MB("WhisperX is already running.\nWait for it to finish or close the progress window.", "WhisperX dictation", 0)
    return
  end

  local py, transcribe_py, lyrics_dir = get_paths()
  if not file_exists_io(py) then
    r.MB(
      "Python venv not found:\n" .. py .. "\n\n"
        .. "Create it in the parent of WhisperX Lyrics:\n"
        .. "  python3.13 -m venv .venv_whisperx\n"
        .. "  source .venv_whisperx/bin/activate && pip install whisperx",
      "WhisperX dictation",
      0
    )
    return
  end
  if not file_exists_io(transcribe_py) then
    r.MB("Missing script:\n" .. transcribe_py, "WhisperX dictation", 0)
    return
  end

  local model = "small"
  local model_ret = r.GetExtState("BRYAN_WHISPERX", "MODEL")
  if model_ret and model_ret ~= "" then
    model = model_ret
  end
  local device = r.GetExtState("BRYAN_WHISPERX", "DEVICE")
  if not device or device == "" then
    device = "cpu"
  end
  device = tostring(device):lower():gsub("%s+", "")
  if device ~= "cpu" and device ~= "cuda" and device ~= "mps" then
    device = "cpu"
  end

  local compute_type = r.GetExtState("BRYAN_WHISPERX", "COMPUTE_TYPE")
  if not compute_type or compute_type == "" then
    compute_type = "int8"
  end
  compute_type = tostring(compute_type):lower():gsub("%s+", "")
  if compute_type ~= "int8" and compute_type ~= "float16" and compute_type ~= "float32" then
    compute_type = "int8"
  end

  local lang = r.GetExtState("BRYAN_WHISPERX", "LANGUAGE")
  local interp = r.GetExtState("BRYAN_WHISPERX", "INTERPOLATE_METHOD")
  local chunk_sz = tonumber(r.GetExtState("BRYAN_WHISPERX", "CHUNK_SIZE"))
  local vad_m = r.GetExtState("BRYAN_WHISPERX", "VAD_METHOD")
  vad_m = vad_m and vad_m:lower():gsub("%s+", "") or ""
  local vad_os = tonumber(r.GetExtState("BRYAN_WHISPERX", "VAD_ONSET"))
  local vad_off = tonumber(r.GetExtState("BRYAN_WHISPERX", "VAD_OFFSET"))
  local beam_n = tonumber(r.GetExtState("BRYAN_WHISPERX", "BEAM_SIZE"))
  local align_m = r.GetExtState("BRYAN_WHISPERX", "ALIGN_MODEL")
  align_m = align_m and align_m:match("^%s*(.-)%s*$") or ""

  local proj_root = r.GetProjectPath("") or ""
  local mirror_dir = (proj_root ~= "") and proj_root or lyrics_dir
  local mirror_json = join_path(mirror_dir, "_whisperx_last.json")
  local mirror_tsv = join_path(mirror_dir, "_whisperx_last.words.tsv")
  local mirror_plain = join_path(mirror_dir, "_whisperx_last.plain.txt")
  local debug_log = join_path(mirror_dir, "_whisperx_run.log")
  local progress_file = join_path(mirror_dir, "_whisperx_progress.txt")
  local done_flag = join_path(mirror_dir, "_whisperx_done.txt")

  local function build_inner(media_path, out_json)
    local parts = {
      shell_quote(py),
      "-u",
      shell_quote(transcribe_py),
      "--input",
      shell_quote(media_path),
      "--output",
      shell_quote(out_json),
      "--model",
      shell_quote(model),
      "--device",
      shell_quote(device),
      "--compute_type",
      shell_quote(compute_type),
    }

    if lang and lang ~= "" then
      parts[#parts + 1] = "--language"
      parts[#parts + 1] = shell_quote(lang)
    end

    if interp and interp ~= "" then
      parts[#parts + 1] = "--interpolate_method"
      parts[#parts + 1] = shell_quote(interp)
    end

    if chunk_sz and chunk_sz >= 4 and chunk_sz <= 120 then
      parts[#parts + 1] = "--chunk-size"
      parts[#parts + 1] = tostring(math.floor(chunk_sz + 0.5))
    end

    if vad_m == "silero" or vad_m == "pyannote" then
      parts[#parts + 1] = "--vad-method"
      parts[#parts + 1] = vad_m
    end

    if vad_os and vad_os >= 0.01 and vad_os <= 0.99 then
      parts[#parts + 1] = "--vad-onset"
      parts[#parts + 1] = tostring(vad_os)
    end

    if vad_off and vad_off >= 0.01 and vad_off <= 0.99 then
      parts[#parts + 1] = "--vad-offset"
      parts[#parts + 1] = tostring(vad_off)
    end

    if beam_n and beam_n >= 1 and beam_n <= 50 then
      parts[#parts + 1] = "--beam-size"
      parts[#parts + 1] = tostring(math.floor(beam_n + 0.5))
    end

    if align_m ~= "" then
      parts[#parts + 1] = "--align-model"
      parts[#parts + 1] = shell_quote(align_m)
    end

    parts[#parts + 1] = "--mirror_json"
    parts[#parts + 1] = shell_quote(mirror_json)
    parts[#parts + 1] = "--mirror_tsv"
    parts[#parts + 1] = shell_quote(mirror_tsv)
    parts[#parts + 1] = "--mirror_plain"
    parts[#parts + 1] = shell_quote(mirror_plain)
    parts[#parts + 1] = "--debug_log"
    parts[#parts + 1] = shell_quote(debug_log)
    parts[#parts + 1] = "--progress_file"
    parts[#parts + 1] = shell_quote(progress_file)
    parts[#parts + 1] = "--done_flag"
    parts[#parts + 1] = shell_quote(done_flag)

    return table.concat(parts, " ")
  end

  local jobs, collect_err = collect_selected_dictation_jobs(build_inner)
  if not jobs then
    r.MB(collect_err or "Unknown error", "WhisperX dictation", 0)
    return
  end

  local timeout_ms = parse_timeout_ms()

  r.SetExtState("BRYAN_WHISPERX", "LAST_INNER", jobs[1].inner_cmd, false)
  r.SetExtState("BRYAN_WHISPERX", "LAST_CMD", "/bin/sh -c " .. shell_quote(jobs[1].inner_cmd .. " 2>&1"), false)

  log_line("======== run ========")
  log_line("batch: " .. tostring(#jobs) .. " job(s)")
  for ji, jb in ipairs(jobs) do
    log_line(
      "job "
        .. tostring(ji)
        .. "/" .. tostring(#jobs)
        .. " media: "
        .. jb.media_path
        .. " exists="
        .. tostring(path_exists(jb.media_path))
    )
    log_line("  out_json: " .. jb.out_json)
    log_line("  words TSV: " .. jb.out_tsv)
  end
  log_line("python: " .. py)
  log_line("transcribe script: " .. transcribe_py)
  log_line("mirror (ASCII names): " .. mirror_json)
  log_line("debug log: " .. debug_log)
  log_line("progress file: " .. progress_file)
  log_line("done flag: " .. done_flag)
  log_line("device: " .. device .. " compute_type: " .. compute_type)
  log_line("model: " .. model)
  if lang and lang ~= "" then
    log_line("LANGUAGE extstate: " .. lang)
  end
  if interp and interp ~= "" then
    log_line("INTERPOLATE_METHOD extstate: " .. interp)
  end
  if chunk_sz and chunk_sz >= 4 and chunk_sz <= 120 then
    log_line("CHUNK_SIZE extstate: " .. tostring(math.floor(chunk_sz + 0.5)))
  end
  if vad_m == "silero" or vad_m == "pyannote" then
    log_line("VAD_METHOD extstate: " .. vad_m)
  end
  if vad_os and vad_os >= 0.01 and vad_os <= 0.99 then
    log_line("VAD_ONSET extstate: " .. tostring(vad_os))
  end
  if vad_off and vad_off >= 0.01 and vad_off <= 0.99 then
    log_line("VAD_OFFSET extstate: " .. tostring(vad_off))
  end
  if beam_n and beam_n >= 1 and beam_n <= 50 then
    log_line("BEAM_SIZE extstate: " .. tostring(math.floor(beam_n + 0.5)))
  end
  if align_m ~= "" then
    log_line("ALIGN_MODEL extstate: " .. align_m)
  end
  log_line("ExecProcess timeout_ms (ignored on macOS when using io.popen): " .. tostring(timeout_ms))

  local os_str = r.GetOS() or ""
  local is_win = os_str:match("Win") ~= nil
  local try_bg = not is_win and ext_flag("USE_BACKGROUND", true)

  local function job_state(jb)
    return {
      item = jb.item,
      take = jb.take,
      out_json = jb.out_json,
      out_tsv = jb.out_tsv,
      out_plain = jb.out_plain,
      mirror_json = mirror_json,
      mirror_tsv = mirror_tsv,
      mirror_plain = mirror_plain,
      debug_log = debug_log,
    }
  end

  if try_bg and whisperx_spawn_unix_detached(jobs[1].inner_cmd, done_flag) then
    log_line("background WhisperX spawn OK; defer polling " .. done_flag)
    r.Undo_BeginBlock()
    local gfx_on = false
    if gfx and gfx.init then
      gfx.init("WhisperX transcription", 420, 74, 0, 120, 120)
      gfx_on = true
    else
      log_line("gfx not available; running in background without progress window")
    end
    WX_job = {
      batch_jobs = jobs,
      batch_cur = 1,
      batch_total = #jobs,
      mirror_json = mirror_json,
      mirror_tsv = mirror_tsv,
      mirror_plain = mirror_plain,
      debug_log = debug_log,
      progress_file = progress_file,
      done_flag = done_flag,
      t0 = r.time_precise(),
      max_wait = 4 * 3600 * math.max(1, #jobs),
      gfx_on = gfx_on,
    }
    r.defer(wx_poll)
    return
  end

  if try_bg then
    log_line("background spawn failed; falling back to blocking subprocess")
  end

  local n_jobs = #jobs
  for idx, jb in ipairs(jobs) do
    r.Undo_BeginBlock()
    log_line("starting subprocess (blocking) job " .. tostring(idx) .. "/" .. tostring(n_jobs) .. " …")
    local ret = run_whisperx_shell(jb.inner_cmd, timeout_ms)

    log_line("subprocess capture len=" .. tostring(ret and #ret or 0))

    if not ret or ret == "" then
      log_line("ERROR: empty ExecProcess return")
      r.Undo_EndBlock("WhisperX dictation (failed)", -1)
      r.MB("ExecProcess returned empty output (see REAPER console).", "WhisperX dictation", 0)
      return
    end

    if ret == "-999" then
      log_line("ERROR: -999 timeout")
      r.Undo_EndBlock("WhisperX dictation (failed)", -1)
      r.MB(
        "Timed out waiting for WhisperX.\nSet BRYAN_WHISPERX / TIMEOUT_MS to 0 for no limit.",
        "WhisperX dictation",
        0
      )
      return
    end

    local first_nl = ret:find("\n", 1, true)
    local exit_str = first_nl and ret:sub(1, first_nl - 1) or ret
    local stdout = first_nl and ret:sub(first_nl + 1) or ""
    local exit_code = tonumber(exit_str:match("^%s*(%-?%d+)%s*$")) or 1

    local st = job_state(jb)
    local ok =
      whisperx_finalize(st, exit_code, stdout, {
        batch_index = idx,
        batch_total = n_jobs,
        suppress_success_mb = idx < n_jobs,
      })
    if not ok then
      return
    end
  end
end

main()
