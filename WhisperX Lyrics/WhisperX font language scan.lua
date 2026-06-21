--[[ WhisperX font language scan — OS/2 unicode coverage + heuristic tags, TSV cache.
     Loaded via loadfile from the bridge script (same folder). Not a standalone ReaPack action.

     Cache path: `<script_directory>/WX_font_language_cache.tsv` (tab-separated UTF-8)
     Columns: FontFullName TAB FilePath TAB TagListComma
]]
local trim
trim = function(s)
  return (s or ""):match("^%s*(.-)%s*$") or ""
end

local M = {}

--- @param path string Absolute path inside script folder (provided by caller)
M.CACHE_FILENAME = "WX_font_language_cache.tsv"

local POW = {}
do
  local p = 1
  for i = 1, 32 do
    POW[i] = p
    p = p + p -- 2^(i-1) as Lua number until 31; last entry 2^31 as double loses precision —
    -- use modular check for bit 31
  end
end

local function u32_fix(x)
  x = tonumber(x) or 0
  local m = x % (2 ^ 32)
  if m < 0 then
    m = m + (2 ^ 32)
  end
  return m
end

--- Bitwise AND for 32‑bit masked words only (ranges / OS/2).
function M.band_u32(a, b)
  a, b = u32_fix(a), u32_fix(b)
  local r = 0
  local aa, bb = a, b
  for k = 0, 31 do
    if aa % 2 >= 1 and bb % 2 >= 1 then
      local m = POW[k + 1]
      if k == 31 then
        r = u32_fix(r + 2147483648)
      else
        r = r + m
      end
    end
    aa = math.floor(aa / 2)
    bb = math.floor(bb / 2)
  end
  return u32_fix(r)
end

function M.unicode_bit_set(r1, r2, r3, r4, n)
  if n == nil then
    return false
  end
  local slot = math.floor(n / 32)
  local w
  if slot == 0 then
    w = r1
  elseif slot == 1 then
    w = r2
  elseif slot == 2 then
    w = r3
  elseif slot == 3 then
    w = r4
  else
    return false
  end
  w = u32_fix(w)
  local b = math.fmod(math.floor(n + 0.5), 32)
  if b == 31 then
    return w >= 2147483648
  end
  local mask = POW[b + 1]
  mask = math.floor(mask + 0.5)
  if M.band_u32(w, mask) ~= 0 then
    return true
  end
  return false
end

local function uniq_add(list, txt)
  if not txt or txt == "" then
    return
  end
  for i = 1, #list do
    if list[i] == txt then
      return
    end
  end
  list[#list + 1] = txt
end

--- Map OpenType ulUnicodeRange* bits → short UX tags (MS bit index 0..127).
function M.tags_from_unicode_ranges(r1, r2, r3, r4)
  local tags = {}
  local function chk(n, label)
    if M.unicode_bit_set(r1, r2, r3, r4, n) then
      uniq_add(tags, label)
    end
  end
  chk(9, "Cyrillic")
  chk(7, "Greek")
  chk(11, "Hebrew")
  chk(13, "Arabic")
  chk(15, "Devanagari")
  chk(24, "Thai")
  chk(70, "Tibetan")
  chk(28, "HangulJam")
  chk(52, "HangulCompat")
  chk(56, "HangulSyl")
  chk(49, "Hiragana")
  chk(50, "Katakana")
  chk(53, "Bopomofo")
  chk(54, "CJKEnclosure")
  chk(71, "Syriac")
  chk(73, "Sinhala")
  chk(74, "Myanmar")
  chk(76, "Ethiopic")
  chk(80, "Khmer")
  for _, n in ipairs({ 0, 1, 2, 3, 29, 4, 30 }) do
    if M.unicode_bit_set(r1, r2, r3, r4, n) then
      uniq_add(tags, "Latin")
      break
    end
  end
  if M.unicode_bit_set(r1, r2, r3, r4, 38) or M.unicode_bit_set(r1, r2, r3, r4, 89) then
    uniq_add(tags, "Math")
  end
  if M.unicode_bit_set(r1, r2, r3, r4, 46) then
    uniq_add(tags, "Symbols")
  end
  if M.unicode_bit_set(r1, r2, r3, r4, 57) then
    uniq_add(tags, "NonBMP")
  end
  if M.unicode_bit_set(r1, r2, r3, r4, 59) then
    uniq_add(tags, "Han")
  elseif M.unicode_bit_set(r1, r2, r3, r4, 61) then
    uniq_add(tags, "HanCmp")
  elseif M.unicode_bit_set(r1, r2, r3, r4, 54) then
    uniq_add(tags, "HanEnc")
  end
  if M.unicode_bit_set(r1, r2, r3, r4, 49) or M.unicode_bit_set(r1, r2, r3, r4, 50) then
    uniq_add(tags, "Japanese")
  end
  if M.unicode_bit_set(r1, r2, r3, r4, 56) then
    uniq_add(tags, "Korean")
  end
  local hasJam = false
  for i = 1, #tags do
    if tags[i] == "HangulJam" or tags[i] == "HangulCompat" then
      hasJam = tags[i]
      break
    end
  end
  local hasBigHangul = false
  for i = 1, #tags do
    if tags[i] == "HangulSyl" then
      hasBigHangul = true
      break
    end
  end
  if hasJam and hasBigHangul then
    local p = {}
    for i = 1, #tags do
      local t = tags[i]
      if t ~= "HangulJam" and t ~= "HangulCompat" then
        p[#p + 1] = t
      end
    end
    tags = p
  end
  if hasBigHangul or hasJam then
    uniq_add(tags, "Korean")
  end
  table.sort(tags)
  local seen = {}
  local fin = {}
  for i = 1, #tags do
    local t = tags[i]
    if not seen[t] then
      seen[t] = true
      fin[#fin + 1] = t
    end
  end
  return table.concat(fin, ", ")
end

function M.tags_from_family_name(nm)
  local l = trim(nm):lower()
  local t = {}
  local function hx(s)
    if l:find(s, 1, true) then
      uniq_add(t, s)
    end
  end
  if l:find(" noto ") or l:find("^noto") then
    hx("Noto")
  end
  if l:find("jp") or l:find("jpn") then
    hx("JPfam")
  end
  if l:find("kr") then
    hx("KRfam")
  end
  if l:find("sc\"") or l:find("%scc?$") then
    hx("SCfam")
  end
  if l:find("tc\"") then
    hx("TCfam")
  end
  if l:find("korean") or l:find("hangul") then
    uniq_add(t, "Korean")
  end
  if l:find(" jpan") then
    uniq_add(t, "Japanese")
  end
  if l:find("arabic") or l:find("naskh") or l:find("nasta") then
    uniq_add(t, "Arabic")
  end
  if #t == 0 then
    return ""
  end
  table.sort(t)
  local u = {}
  local s2 = {}
  for i = 1, #t do
    if not s2[t[i]] then
      s2[t[i]] = true
      u[#u + 1] = t[i]
    end
  end
  return table.concat(u, ", ")
end

function M.rd_be16(s, i)
  if not s or i + 1 > #s then
    return nil
  end
  local a, b = s:byte(i, i + 1)
  if not b then
    return nil
  end
  return a * 256 + b
end

function M.rd_be32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  if not d then
    return nil
  end
  return ((((a * 256 + b) * 256) + c) * 256) + d
end

local function sfnt_slice(data, face_index_0)
  face_index_0 = math.max(0, math.floor(face_index_0 or 0))
  if #data < 12 then
    return nil
  end
  local tag = data:sub(1, 4)
  if tag == "ttcf" then
    if #data < 12 then
      return nil
    end
    local nFonts = M.rd_be32(data, 5)
    if not nFonts or nFonts <= face_index_0 then
      return nil
    end
    local off = M.rd_be32(data, 9 + face_index_0 * 4)
    if not off or off < 0 or off + 24 > #data then
      return nil
    end
    return data, off + 1
  end
  return data, 1
end

function M.os2_tags_from_sfnt(blob)
  if not blob then
    return ""
  end
  local dat, origin = sfnt_slice(blob, 0)
  if not origin then
    return ""
  end
  local scaler = dat:sub(origin, origin + 3)
  if scaler ~= "OTTO" and scaler ~= "true" and scaler ~= "typ1" and scaler ~= "\0\1\0\0" then
    --- some fonts start with JUST \0\x01\0\0 ?
    --- accept \0\x01\0\x0 as TT
    if dat:byte(origin + 1) ~= 1 or dat:byte(origin + 2) ~= 0 or dat:byte(origin + 3) ~= 0 then
      if scaler ~= "true" then
        return ""
      end
    end
  end
  local numTables = M.rd_be16(dat, origin + 4)
  if not numTables or numTables <= 0 or numTables > 2048 then
    return ""
  end
  local iix = origin + 12
  local os2_off, os2_len
  local iend = math.min(#dat, iix + numTables * 16 - 1)
  while iix + 15 <= iend do
    local tg = dat:sub(iix, iix + 3)
    local toff = M.rd_be32(dat, iix + 8)
    local tlen = M.rd_be32(dat, iix + 12)
    if tg == "OS/2" and toff and tlen then
      local abs = toff + 1
      if abs + math.max(92, math.min(tlen, 126)) <= #dat then
        os2_off = abs
        os2_len = tlen
        break
      end
    end
    iix = iix + 16
  end
  if not os2_off or os2_len < 90 then
    return ""
  end
  local ver = M.rd_be16(dat, os2_off)
  if ver == nil or ver < 1 then
    return ""
  end
  if os2_off + 100 > #dat then
    return ""
  end
  local r1 = M.rd_be32(dat, os2_off + 84)
  local r2 = M.rd_be32(dat, os2_off + 88)
  local r3 = M.rd_be32(dat, os2_off + 92)
  local r4 = M.rd_be32(dat, os2_off + 96)
  if not r4 then
    return ""
  end
  if r1 == 0 and r2 == 0 and r3 == 0 and r4 == 0 then
    return ""
  end
  return M.tags_from_unicode_ranges(r1, r2, r3, r4)
end

function M.tags_from_font_path(path)
  path = trim(path or "")
  if path == "" then
    return ""
  end
  local fh = io.open(path, "rb")
  if not fh then
    return ""
  end
  local chunk = fh:read(786432)
  fh:close()
  if type(chunk) ~= "string" or #chunk < 128 then
    return ""
  end
  local ttags = trim(M.os2_tags_from_sfnt(chunk))
  if ttags ~= "" then
    return ttags
  end
  return ""
end

function M.cache_filepath(script_dir_abs)
  local d = trim(script_dir_abs or "")
  if d ~= "" then
    d = d:gsub("/$", ""):gsub("\\$", "")
    return d .. "/" .. M.CACHE_FILENAME
  end
  return M.CACHE_FILENAME
end

function M.disk_load_map(filepath)
  local m = {}
  local fh = io.open(filepath or "", "rb")
  if not fh then
    return m
  end
  local s = fh:read("*a") or ""
  fh:close()
  for ln in s:gmatch("[^\r\n]+") do
    if ln ~= "" and not ln:match("^#") then
      local a, _b, c = ln:match("^([^\t]*)\t([^\t]*)\t(.*)$")
      if a then
        a, c = trim(a), trim(c or "")
        if a ~= "" then
          m[a] = trim(c or "")
        end
      end
    end
  end
  return m
end

function M.disk_save(filepath, rows)
  local fh = io.open(filepath, "w+b")
  if not fh then
    return false
  end
  fh:write("# WX font language scan cache v2 (tab-separated). Regenerated by bridge “Rescan fonts”.\n")
  for i = 1, #(rows or {}) do
    local it = rows[i]
    local nm = trim(it.name or "")
    if nm ~= "" then
      fh:write(
        nm:gsub("\t", " ")
          .. "\t"
          .. trim(it.path_hint or ""):gsub("\t", " ")
          .. "\t"
          .. trim(it.tags or ""):gsub("\t", " ")
          .. "\n"
      )
    end
  end
  fh:close()
  return true
end

function M.apply_cached_tags_to(items, filepath)
  if type(items) ~= "table" then
    return
  end
  local mp = M.disk_load_map(filepath)
  if not next(mp) then
    return
  end
  for i = 1, #items do
    local it = items[i]
    local nm = trim(it and it.name or "")
    local tg = nm ~= "" and mp[nm]
    if type(tg) == "string" and trim(tg) ~= "" then
      it.tags = trim(tg)
    end
  end
end

local function profiler_mac(entries)
  local names = entries or {}
  local seen = {}
  local pending_path = nil
  local p = io.popen("system_profiler SPFontsDataType 2>/dev/null")
  if not p then
    return names
  end
  local out = p:read("*a") or ""
  p:close()
  local cur_name
  for ln in out:gmatch("[^\r\n]+") do
    local pv = ln:match("^%s*Location:%s*(/.+)%s*$")
    if pv then
      pending_path = trim(pv)
    end
    local nm = ln:match("^%s*Full Name:%s*(.-)%s*$")
    if nm and trim(nm) ~= "" then
      cur_name = trim(nm)
    end
    if cur_name and not seen[cur_name] then
      names[#names + 1] = {
        name = cur_name,
        path_hint = pending_path or "",
        tags = "",
      }
      seen[cur_name] = true
      cur_name = nil
    end
  end
  return names
end

local function scan_fc_list()
  local names = {}
  local seen = {}
  local p = io.popen("fc-list -f '%{family}\\n' 2>/dev/null")
  if not p then
    return names
  end
  local blob = p:read("*a") or ""
  p:close()
  for ln in blob:gmatch("[^\r\n]+") do
    local fam = trim(ln)
    if fam ~= "" and not seen[fam] then
      names[#names + 1] = { name = fam, path_hint = "", tags = "" }
      seen[fam] = true
    end
  end
  return names
end

function M.load_system_font_items()
  local names = {}
  local osname = ((reaper.GetOS and reaper.GetOS()) or ""):lower()
  local mac_like = osname:find("mac", 1, true) or osname:find("osx", 1, true) or osname:find("darwin", 1, true)
  if mac_like then
    profiler_mac(names)
  end
  if #names == 0 then
    names = scan_fc_list()
  end
  if #names == 0 then
    local fallback = {
      "Arial",
      "Helvetica",
      "Times New Roman",
      "Courier New",
      "Verdana",
      "Hiragino Sans",
      "Noto Sans",
    }
    local seen = {}
    for i = 1, #names do
      seen[names[i].name] = true
    end
    for i = 1, #fallback do
      local nm = fallback[i]
      if not seen[nm] then
        names[#names + 1] = { name = nm, path_hint = "", tags = "" }
        seen[nm] = true
      end
    end
  end
  table.sort(names, function(a, b)
    return (a.name or ""):lower() < (b.name or ""):lower()
  end)
  return names
end

function M.enrich_with_file_tags(items, max_files)
  max_files = math.max(8, math.min(8000, math.floor(tonumber(max_files) or 4000)))
  local n = 0
  for i = 1, #items do
    if n >= max_files then
      break
    end
    local it = items[i]
    local ph = trim(it.path_hint or "")
    if ph ~= "" then
      local tg = M.tags_from_font_path(ph)
      if tg ~= "" then
        it.tags = tg
      end
      n = n + 1
    end
  end
  for i = 1, #items do
    local it = items[i]
    if trim(it.tags or "") == "" then
      local hx = M.tags_from_family_name(it.name or "")
      if hx ~= "" then
        it.tags = hx
      end
    end
  end
end

return M
