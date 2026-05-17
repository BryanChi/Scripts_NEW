-- WhisperX word overlay — shared core (loaded by action scripts; not a ReaPack action).
-- @version 1.69

local r = reaper

local SENTINEL = "BRYAN_WX_WORD_OVERLAY_V1"
local MAX_WORDS = 1200
--- Experimental: use marker name exactly as returned by REAPER/chunk (no wx| strip, BOM/trim, UTF-8 tail repair, CRLF→space).
local READ_MARKER_WORDS_AS_IS = true
local ANIM_MAX_DUPES = 8

local PRESET_WORD = "word"
local PRESET_LINE_FULL = "line_full"
local PRESET_LINE_GROW = "line_grow"
local PRESET_LINE_TRIPLE = "line_triple"
local PRESET_LINE_STAIRS = "line_stairs"

--- Per-item word style blob (same format as bridge WORD_STYLE_BLOB / extstate).
local OVERLAY_ITEM_EXT_WORD_STYLES = "P_EXT:BRYAN_WX_OVERLAY_WORD_STYLES"
local OVERLAY_ITEM_EXT_ROW_SPACING = "P_EXT:BRYAN_WX_OVERLAY_ROW_SPACING"

--- WhisperX / REAPER use fractional seconds for srcpos; native color is usually a large integer.
local function _has_fractional_seconds(n)
  if type(n) ~= "number" or n ~= n then
    return false
  end
  return math.abs(n - math.floor(n + 0.5)) > 1e-9
end

--- Given the two numeric tails from GetTakeMarker (color + srcpos in some order), return srcpos.
local function _pick_srcpos_from_pair(n3, n4)
  if type(n3) ~= "number" and type(n4) == "number" then
    return n4
  end
  if type(n4) ~= "number" and type(n3) == "number" then
    return n3
  end
  if type(n3) ~= "number" or type(n4) ~= "number" then
    return nil
  end
  local f3, f4 = _has_fractional_seconds(n3), _has_fractional_seconds(n4)
  if f3 and not f4 then
    return n3
  end
  if f4 and not f3 then
    return n4
  end
  if f3 and f4 then
    return n4
  end
  -- both whole numbers: REAPER order is (color, srcpos) so prefer n4; if n3 is huge and n4 small, n4 is time
  if math.abs(n3) > 1e6 and math.abs(n4) < 1e9 then
    return n4
  end
  if math.abs(n4) > 1e6 and math.abs(n3) < 1e9 then
    return n3
  end
  return n4
end

--- All numeric tails after the marker name (color/srcpos/extra vary by REAPER build).
local function take_marker_name_and_nums(take, idx)
  if not r.GetTakeMarker then
    return nil, nil
  end
  local p = table.pack(r.GetTakeMarker(take, idx))
  if type(p[1]) == "number" and type(p[2]) == "string" then
    local nums = { p[1] }
    for k = 3, p.n do
      if type(p[k]) == "number" then
        nums[#nums + 1] = p[k]
      end
    end
    return p[2], nums
  end
  local i = 1
  if type(p[i]) == "boolean" then
    if not p[i] then
      return nil, nil
    end
    i = i + 1
  end
  if type(p[i]) ~= "string" then
    return nil, nil
  end
  local name = p[i]
  local nums = {}
  for k = i + 1, p.n do
    if type(p[k]) == "number" then
      nums[#nums + 1] = p[k]
    end
  end
  return name, nums
end

--- mode: nil = pick color vs srcpos from first two numbers; "last" = use last number (some layouts); "pair23" = pick(nums[2],nums[3]).
local function srcpos_from_numlist(nums, mode)
  if not nums or #nums == 0 then
    return nil
  end
  if mode == "last" then
    return nums[#nums]
  end
  if mode == "pair23" and #nums >= 3 then
    return _pick_srcpos_from_pair(nums[2], nums[3])
  end
  if #nums == 1 then
    return nums[1]
  end
  if mode == nil then
    return nums[1]
  end
  return _pick_srcpos_from_pair(nums[1], nums[2])
end

local function get_take_marker_srcpos_name(take, idx, mode)
  local name, nums = take_marker_name_and_nums(take, idx)
  if not name then
    return nil, nil, nil
  end
  return name, nil, srcpos_from_numlist(nums, mode)
end

--- Peel bytes off the end until the string is valid UTF-8. Fixes marker names truncated mid-codepoint (Lua byte sub caps).
--- If nothing valid remains but the raw string had bytes, return U+FFFD so the word keeps a slot/timing.
local function utf8_trim_invalid_suffix(s)
  if type(s) ~= "string" or s == "" then
    return s
  end
  if utf8 and utf8.len then
    local t = s
    while #t > 0 do
      local ok = pcall(utf8.len, t)
      if ok then
        return t
      end
      t = t:sub(1, -2)
    end
    return #s > 0 and "\239\191\189" or ""
  end
  return s
end

--- Legacy WhisperX: text after wx| (ASCII or fullwidth ｜), case-insensitive; strips BOM / leading space.
local function word_text_after_wx_prefix(name)
  if type(name) ~= "string" then
    return nil
  end
  local s = name:gsub("^\239\187\191", ""):gsub("^%s+", "")
  -- ASCII | or fullwidth vertical line U+FF5C (UTF-8 EF BD 9C)
  local rest = s:match("^[Ww][Xx][|](.*)$") or s:match("^[Ww][Xx][\239\189\156](.*)$")
  if rest then
    rest = rest:gsub("^%s+", "")
    if rest ~= "" then
      return rest
    end
  end
  return nil
end

--- Display word for a take marker (see READ_MARKER_WORDS_AS_IS).
--- Normal path: BOM/trim, legacy wx| strip, UTF-8 tail repair, CRLF flattened when collecting words.
local function take_marker_word_text(name)
  if READ_MARKER_WORDS_AS_IS then
    if type(name) ~= "string" or name == "" then
      return nil
    end
    --- Newlines inside a marker name would break the triple-stack editor (newline = phrase boundary).
    return name:gsub("[\r\n]+", " ")
  end
  local wx = word_text_after_wx_prefix(name)
  if wx then
    wx = utf8_trim_invalid_suffix(wx)
    return wx ~= "" and wx or nil
  end
  if type(name) ~= "string" then
    return nil
  end
  local s = name:gsub("^\239\187\191", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then
    return nil
  end
  s = utf8_trim_invalid_suffix(s)
  return s ~= "" and s or nil
end

local function collect_wx_words_inner(take, mode)
  local words = {}
  if not take or not r.GetNumTakeMarkers then
    return words
  end
  local n = r.GetNumTakeMarkers(take)
  for i = 0, n - 1 do
    local name, _, srcpos = get_take_marker_srcpos_name(take, i, mode)
    local w = take_marker_word_text(name)
    if w and type(srcpos) == "number" then
      if not READ_MARKER_WORDS_AS_IS then
        w = w:gsub("[\r\n]", " ")
      end
      words[#words + 1] = { t = srcpos, w = w }
    end
  end
  local out = {}
  for i = 1, #words do
    local prev = out[#out]
    if not prev or math.abs(words[i].t - prev.t) > 1e-9 or prev.w ~= words[i].w then
      out[#out + 1] = words[i]
    end
  end
  return out
end

local function time_span(words)
  if #words < 2 then
    return 0
  end
  local mn = words[1].t
  local mx = words[1].t
  for i = 2, #words do
    local t = words[i].t
    if t < mn then
      mn = t
    end
    if t > mx then
      mx = t
    end
  end
  return mx - mn
end

--- If every marker time collapses (~same t), try alternate GetTakeMarker numeric layouts before giving up.
local function collect_wx_words_from_api(take)
  local words = collect_wx_words_inner(take, nil)
  if #words > 12 and time_span(words) < 1e-5 then
    local w2 = collect_wx_words_inner(take, "last")
    if time_span(w2) > time_span(words) + 1e-6 then
      words = w2
    else
      local w3 = collect_wx_words_inner(take, "pair23")
      if time_span(w3) > time_span(words) + 1e-6 then
        words = w3
      end
    end
  end
  return words
end

--- Take marker source times from item state chunk (ReaTeam: "TKM pos name color ..." — field 1 is seconds).
--- GetTakeMarker() return layouts are unreliable across REAPER builds; TKM matches what SetTakeMarker wrote.
local function take_index_for_take(item, take)
  if not item or not take or not r.CountTakes or not r.GetMediaItemTake then
    return nil
  end
  local n = r.CountTakes(item)
  for i = 0, n - 1 do
    if r.GetMediaItemTake(item, i) == take then
      return i
    end
  end
  return nil
end

local function parse_chunk_quoted_string(rest)
  if type(rest) ~= "string" or rest:sub(1, 1) ~= '"' then
    return nil
  end
  local out = {}
  local i = 2
  while i <= #rest do
    local c = rest:sub(i, i)
    if c == '"' then
      if rest:sub(i + 1, i + 1) == '"' then
        out[#out + 1] = '"'
        i = i + 2
      else
        return table.concat(out)
      end
    elseif c == "\\" and i < #rest then
      out[#out + 1] = rest:sub(i + 1, i + 1)
      i = i + 2
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

local function parse_tkm_line(line)
  if type(line) ~= "string" then
    return nil, nil
  end
  local num_s, rest = line:match("^%s*TKM%s+([-%d%.eE+]+)%s+(.+)$")
  if not num_s or not rest then
    return nil, nil
  end
  local pos = tonumber(num_s)
  if not pos then
    return nil, nil
  end
  rest = rest:match("^%s*(.*)$") or rest
  local name
  local q = parse_chunk_quoted_string(rest)
  if q then
    name = q
  else
    name = rest:match("^(%S+)")
  end
  if not name or name == "" then
    return nil, nil
  end
  return pos, name
end

local function collect_wx_words_from_item_chunk(item, take)
  if not item or not take or not r.GetItemStateChunk then
    return nil
  end
  local tidx = take_index_for_take(item, take)
  if not tidx or tidx < 0 then
    return nil
  end
  local ok, chunk = r.GetItemStateChunk(item, "", false)
  if not ok or type(chunk) ~= "string" or chunk == "" then
    return nil
  end
  local cur_take = -1
  local words = {}
  for line in (chunk .. "\n"):gmatch("(.-)\r?\n") do
    if line:match("^%s*TAKE%s+[A-Z]") then
      cur_take = cur_take + 1
    elseif cur_take == tidx then
      local pos, mname = parse_tkm_line(line)
      if pos and mname then
        local w = take_marker_word_text(mname)
        if w then
          if not READ_MARKER_WORDS_AS_IS then
            w = w:gsub("[\r\n]", " ")
          end
          words[#words + 1] = { t = pos, w = w }
        end
      end
    end
  end
  if #words == 0 then
    return nil
  end
  local out = {}
  for i = 1, #words do
    local prev = out[#out]
    if not prev or math.abs(words[i].t - prev.t) > 1e-9 or prev.w ~= words[i].w then
      out[#out + 1] = words[i]
    end
  end
  return out
end

local function collect_wx_words(item, take)
  local from_chunk = collect_wx_words_from_item_chunk(item, take)
  local from_api = collect_wx_words_from_api(take)
  if from_api and #from_api > 0 and time_span(from_api) >= 1e-5 then
    return from_api
  end
  if from_chunk and #from_chunk > 0 then
    if not from_api or #from_api == 0 or time_span(from_chunk) > time_span(from_api) + 1e-6 then
      return from_chunk
    end
  end
  return from_api
end

--- Prefer active take if it has wx words; otherwise first take on the item that does.
local function find_take_and_wx_words(item)
  local active = r.GetActiveTake(item)
  if active then
    local w = collect_wx_words(item, active)
    if #w > 0 then
      return active, w, false
    end
  end
  if r.CountTakes and r.GetMediaItemTake then
    local n = r.CountTakes(item)
    if n and n > 0 then
      for i = 0, n - 1 do
        local t = r.GetMediaItemTake(item, i)
        if t and t ~= active then
          local w = collect_wx_words(item, t)
          if #w > 0 then
            return t, w, true
          end
        end
      end
      local fallback = r.GetMediaItemTake(item, 0)
      return fallback or active, {}, false
    end
  end
  return active, {}, false
end

local function source_length_for_take(take)
  local src = r.GetMediaItemTake_Source(take)
  if not src then
    return nil
  end
  if r.GetMediaSourceLength then
    local len = r.GetMediaSourceLength(src)
    if type(len) == "number" and len > 0 then
      return len
    end
  end
  return nil
end

--- Escape text for use inside EEL double-quoted string literals ("...") passed to gfx_* string functions.
--- EEL2: # is only for named strings (#name), not #\"literal\" — use \"word\" instead (see Cockos EEL2 string docs).
local function escape_eel_dq_string(s)
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("[\r\n]", " ")
  -- ASCII | is a column delimiter in VIDEO_EFFECT CODE chunk lines; use fullwidth ｜ for display.
  s = s:gsub("|", "\239\189\156")
  return s
end

local function fmt_eel_num(x)
  if type(x) ~= "number" or x ~= x then
    return "0"
  end
  return string.format("%.17g", x)
end

local ANIM_SCOPE_EVERY_WORD = 0
local ANIM_SCOPE_PHRASE_FIRST = 1
local ANIM_SCOPE_ROW_FIRST = 2

local ANIM_TYPE_NONE = 0
local ANIM_TYPE_FADE = 1
local ANIM_TYPE_ZOOM_IN = 2
local ANIM_TYPE_ZOOM_OUT = 3
local ANIM_TYPE_SLIDE_LEFT = 4
local ANIM_TYPE_SLIDE_RIGHT = 5
local ANIM_TYPE_SLIDE_UP = 6
local ANIM_TYPE_SLIDE_DOWN = 7
local ANIM_TYPE_WHIP_LEFT = 8
local ANIM_TYPE_WHIP_RIGHT = 9
local ANIM_TYPE_POP = 10
local ANIM_TYPE_PUNCH = 11
local ANIM_TYPE_SQUASH = 12
local ANIM_TYPE_STRETCH = 13
local ANIM_TYPE_DROP_BOUNCE = 14
local ANIM_TYPE_RISE_BOUNCE = 15
local ANIM_TYPE_DRIFT_LEFT = 16
local ANIM_TYPE_DRIFT_RIGHT = 17
local ANIM_TYPE_SHAKE = 18
local ANIM_TYPE_JITTER = 19
local ANIM_TYPE_WAVE = 20
local ANIM_TYPE_ORBIT = 21
local ANIM_TYPE_SPIRAL = 22
local ANIM_TYPE_STAMP = 23
local ANIM_TYPE_ECHO_TRAIL = 24
local ANIM_TYPE_CLONE_BURST = 25
local ANIM_TYPE_BLUR = 26
local ANIM_TYPE_CUSTOM = 27
local ANIM_TYPE_WIPE_REVEAL = 28
local ANIM_TYPE_LAST = ANIM_TYPE_WIPE_REVEAL

--- ANIM_TYPE_REV extstate (bridge): >=3 means ids are already Blur=26, Custom=27, Wipe=28, custom 29+.
--- Intermediate "compact" build had no Blur row (26=Custom, 27=Wipe, 28+=custom) — remap to insert Blur at 26.
local function migrate_anim_type_compact_to_v3(v)
  v = math.floor(tonumber(v) or 0)
  if v < 26 then
    return v
  end
  if v >= 28 then
    return v + 1
  end
  if v == 27 then
    return ANIM_TYPE_WIPE_REVEAL
  end
  if v == 26 then
    return ANIM_TYPE_CUSTOM
  end
  return v
end

local function migrate_anim_type_id(v, section)
  v = math.floor(tonumber(v) or 0)
  if type(section) == "string" and section ~= "" then
    local rev = math.floor(tonumber(r.GetExtState(section, "ANIM_TYPE_REV")) or 0)
    if rev >= 3 then
      return v
    end
  end
  return migrate_anim_type_compact_to_v3(v)
end

local WSTYLE_BOLD = 1
local WSTYLE_ITALIC = 2
local WSTYLE_SHADOW = 4
local WSTYLE_HIGHLIGHT = 8
local WSTYLE_OUTLINE = 16
local WSTYLE_UNDERLINE = 32
local WSTYLE_PSEUDO_BOLD = 64
local WSTYLE_PSEUDO_SLANT = 128

local ANIM_CURVE_LINEAR = 0
local ANIM_CURVE_IN_QUAD = 1
local ANIM_CURVE_OUT_QUAD = 2
local ANIM_CURVE_INOUT_QUAD = 3
local ANIM_CURVE_IN_EXP = 4
local ANIM_CURVE_OUT_EXP = 5
local ANIM_CURVE_INOUT_EXP = 6
local ANIM_CURVE_IN_LOG = 7
local ANIM_CURVE_OUT_LOG = 8
local ANIM_CURVE_BACK = 9
local ANIM_CURVE_ELASTIC = 10
local ANIM_GRAPH_CURVE_LINEAR = 0
local ANIM_GRAPH_CURVE_IN_QUAD = 1
local ANIM_GRAPH_CURVE_OUT_QUAD = 2
local ANIM_GRAPH_CURVE_INOUT_QUAD = 3
local ANIM_GRAPH_CURVE_SQUARE = 4
local ANIM_GRAPH_CURVE_IN_LOG = 5
local ANIM_GRAPH_CURVE_IN_EXP = 6
local ANIM_GRAPH_CURVE_LAST = ANIM_GRAPH_CURVE_IN_EXP
--- Path graph only: stronger ease-in log / exp than old 9 / ln(1000) (still 0→1 at u=1).
local ANIM_GRAPH_LOG_K = 99
local ANIM_GRAPH_EXP_A = 13.815511 -- ln(1e6)

local function anim_curve_expr(curve_id, v, bounce)
  curve_id = math.floor(tonumber(curve_id) or 0)
  bounce = bounce or "0.7"
  if curve_id == ANIM_CURVE_IN_QUAD then
    return "(" .. v .. "*" .. v .. ")"
  end
  if curve_id == ANIM_CURVE_OUT_QUAD then
    return "(1-(1-" .. v .. ")*(1-" .. v .. "))"
  end
  if curve_id == ANIM_CURVE_INOUT_QUAD then
    return "((" .. v .. " < 0.5) ? (2*" .. v .. "*" .. v .. ") : (1-((2-2*" .. v .. ")*(2-2*" .. v .. "))/2))"
  end
  if curve_id == ANIM_CURVE_IN_EXP then
    return "((" .. v .. " <= 0) ? (0) : ((exp(6.907755*" .. v .. ")-1)/999))"
  end
  if curve_id == ANIM_CURVE_OUT_EXP then
    return "((" .. v .. " >= 1) ? (1) : (1-(exp(6.907755*(1-" .. v .. "))-1)/999))"
  end
  if curve_id == ANIM_CURVE_INOUT_EXP then
    return "((" .. v
      .. " < 0.5) ? (((exp(13.81551*" .. v
      .. ")-1)/9999)*0.5) : (1-(((exp(13.81551*(1-" .. v .. "))-1)/9999)*0.5)))"
  end
  if curve_id == ANIM_CURVE_IN_LOG then
    return "(log(1+9*" .. v .. ")/2.302585)"
  end
  if curve_id == ANIM_CURVE_OUT_LOG then
    return "(1-log(1+9*(1-" .. v .. "))/2.302585)"
  end
  if curve_id == ANIM_CURVE_BACK then
    local back = "("
      .. v
      .. "*"
      .. v
      .. "*((2.70158)*"
      .. v
      .. "-1.70158))"
    return "(" .. v .. "+" .. bounce .. "*(" .. back .. "-" .. v .. "))"
  end
  if curve_id == ANIM_CURVE_ELASTIC then
    local elastic = "(("
      .. v
      .. " <= 0) ? 0 : (("
      .. v
      .. " >= 1) ? 1 : (pow(2,-10*"
      .. v
      .. ")*sin(("
      .. v
      .. "*10-0.75)*2.094395)*"
      .. "+1)))"
    return "(" .. v .. "+" .. bounce .. "*(" .. elastic .. "-" .. v .. "))"
  end
  return v
end

local function anim_graph_curve_expr(curve_id, uvar)
  curve_id = math.floor(tonumber(curve_id) or 0)
  if curve_id == ANIM_GRAPH_CURVE_IN_QUAD then
    return "(" .. uvar .. "*" .. uvar .. ")"
  end
  if curve_id == ANIM_GRAPH_CURVE_OUT_QUAD then
    return "(1-(1-" .. uvar .. ")*(1-" .. uvar .. "))"
  end
  if curve_id == ANIM_GRAPH_CURVE_INOUT_QUAD then
    return "((" .. uvar .. " < 0.5) ? (2*" .. uvar .. "*" .. uvar .. ") : (1-((2-2*" .. uvar .. ")*(2-2*" .. uvar .. "))/2))"
  end
  if curve_id == ANIM_GRAPH_CURVE_SQUARE then
    return "((" .. uvar .. " < 1) ? 0 : 1)"
  end
  if curve_id == ANIM_GRAPH_CURVE_IN_LOG then
    return "(log(1+" .. tostring(ANIM_GRAPH_LOG_K) .. "*" .. uvar .. ")/log(" .. tostring(ANIM_GRAPH_LOG_K + 1) .. "))"
  end
  if curve_id == ANIM_GRAPH_CURVE_IN_EXP then
    local exp_d = math.exp(ANIM_GRAPH_EXP_A) - 1
    return "((("
      .. uvar
      .. " <= 0) ? (0) : (("
      .. uvar
      .. " >= 1) ? (1) : ((exp("
      .. fmt_eel_num(ANIM_GRAPH_EXP_A)
      .. "*"
      .. uvar
      .. ")-1)/"
      .. fmt_eel_num(exp_d)
      .. "))))"
  end
  return uvar
end

--- In Log ↔ Linear ↔ In Exp: smooththrough-weighted (smoothstep on |b|, zero slope through linear at b=0). Baked coeffs for codegen.
local function anim_graph_curve_mode1_blend_eel(uvar, b)
  b = math.max(-1, math.min(1, tonumber(b) or 0))
  local exp_d = math.exp(ANIM_GRAPH_EXP_A) - 1
  local ylog = "(log(1+" .. tostring(ANIM_GRAPH_LOG_K) .. "*" .. uvar .. ")/log(" .. tostring(ANIM_GRAPH_LOG_K + 1) .. "))"
  local ylin = uvar
  local y_in_exp = "((("
    .. uvar
    .. " <= 0) ? (0) : (("
    .. uvar
    .. " >= 1) ? (1) : ((exp("
    .. fmt_eel_num(ANIM_GRAPH_EXP_A)
    .. "*"
    .. uvar
    .. ")-1)/"
    .. fmt_eel_num(exp_d)
    .. "))))"
  local sn = (b <= 0) and math.min(1, -b) or 0
  local sp = (b >= 0) and math.min(1, b) or 0
  local function smooth01(s)
    if s <= 0 then
      return 0
    end
    if s >= 1 then
      return 1
    end
    return s * s * (3 - 2 * s)
  end
  local w_log = smooth01(sn)
  local w_exp = smooth01(sp)
  local w_lin = math.max(0, 1 - w_log - w_exp)
  return "("
    .. fmt_eel_num(w_log)
    .. "*"
    .. ylog
    .. "+"
    .. fmt_eel_num(w_lin)
    .. "*"
    .. "("
    .. ylin
    .. ")+"
    .. fmt_eel_num(w_exp)
    .. "*"
    .. y_in_exp
    .. ")"
end

local function anim_graph_curve_blend_linear_chosen_eel(curve_id, uvar, strength)
  curve_id = math.floor(tonumber(curve_id) or 0)
  local sm = math.max(0, math.min(1, math.abs(tonumber(strength) or 0)))
  local yc = anim_graph_curve_expr(curve_id, uvar)
  return "(" .. uvar .. "+(" .. yc .. "-" .. uvar .. ")*" .. fmt_eel_num(sm) .. ")"
end

local function anim_graph_seg_ease_expr(curve_id, uvar, seg_blend)
  curve_id = math.floor(tonumber(curve_id) or 0)
  if type(seg_blend) == "number" and seg_blend == seg_blend then
    if
      curve_id == ANIM_GRAPH_CURVE_LINEAR
      or curve_id == ANIM_GRAPH_CURVE_IN_LOG
      or curve_id == ANIM_GRAPH_CURVE_IN_EXP
    then
      return anim_graph_curve_mode1_blend_eel(uvar, seg_blend)
    end
    return anim_graph_curve_blend_linear_chosen_eel(curve_id, uvar, seg_blend)
  end
  return anim_graph_curve_expr(curve_id, uvar)
end

local function parse_anim_graph_blob(blob)
  if type(blob) ~= "string" or blob == "" then
    return nil
  end
  local points, curves = {}, {}
  local pblob, cblob = blob, ""
  local semi = blob:find(";", 1, true)
  if semi then
    pblob = blob:sub(1, semi - 1)
    cblob = blob:sub(semi + 1)
  end
  for tok in pblob:gmatch("[^|]+") do
    local xs, ys, ts = tok:match("^%s*([%-%d%.eE]+)%s*,%s*([%-%d%.eE]+)%s*,%s*([%-%d%.eE]+)%s*$")
    local x, y, t = tonumber(xs), tonumber(ys), tonumber(ts)
    if x and y and t then
      points[#points + 1] = {
        x = math.max(-1, math.min(1, x)),
        y = math.max(-1, math.min(1, y)),
        t = math.max(0, math.min(1, t)),
      }
    end
  end
  if #points < 2 then
    return nil
  end
  table.sort(points, function(a, b)
    return (a.t or 0) < (b.t or 0)
  end)
  points[1].t = 0
  points[#points].t = 1
  local cpart = cblob:match("^%s*(.-)%s*$") or ""
  local bpart
  local til = cpart:find("~", 1, true)
  if til then
    bpart = cpart:sub(til + 1):match("^%s*(.-)%s*$") or ""
    cpart = cpart:sub(1, til - 1):match("^%s*(.-)%s*$") or ""
  end
  for tok in cpart:gmatch("[^,]+") do
    curves[#curves + 1] = math.max(0, math.min(ANIM_GRAPH_CURVE_LAST, math.floor(tonumber(tok) or 0)))
  end
  for i = 1, #points - 1 do
    if curves[i] == nil then
      curves[i] = ANIM_GRAPH_CURVE_LINEAR
    end
  end
  local seg_blends = {}
  if bpart and bpart ~= "" then
    local bi = 1
    for tok in bpart:gmatch("[^,]+") do
      local tt = tok:match("^%s*(.-)%s*$")
      if tt ~= "d" and tt ~= "D" and tt ~= "" then
        local bv = tonumber(tt)
        if bv then
          seg_blends[bi] = math.max(-1, math.min(1, bv))
        end
      end
      bi = bi + 1
    end
  end
  for i = 1, #points - 1 do
    local cid = curves[i]
    local sb = seg_blends[i]
    if cid == ANIM_GRAPH_CURVE_IN_LOG and type(sb) == "number" and sb > 0 and sb <= 1 then
      seg_blends[i] = -sb
    end
  end
  return { points = points, curves = curves, seg_blends = seg_blends }
end

local ANIM_AUTO_META = {
  motion = { min = 0, max = 3, integer = false },
  wiggle = { min = 0, max = 3, integer = false },
  scale = { min = -1, max = 2, integer = false },
  fade = { min = 0, max = 1, integer = false },
  blur = { min = 0, max = 3, integer = false },
  bounce = { min = 0, max = 2, integer = false },
  ghost = { min = 0, max = 2, integer = false },
  dupes = { min = 1, max = ANIM_MAX_DUPES, integer = true },
  twist = { min = -720, max = 720, integer = false },
  dir = { min = -180, max = 180, integer = false },
}

local function parse_anim_auto_blob(blob)
  local out = {}
  if type(blob) ~= "string" or blob == "" then
    return out
  end
  for rec in blob:gmatch("[^\031]+") do
    local p = {}
    local i = 1
    while i <= #rec + 1 do
      local j = rec:find("~", i, true)
      if not j then
        p[#p + 1] = rec:sub(i)
        break
      end
      p[#p + 1] = rec:sub(i, j - 1)
      i = j + 1
    end
    local key = tostring(p[1] or ""):match("^%s*(.-)%s*$")
    if ANIM_AUTO_META[key] then
      local lane = { enabled = tostring(p[2] or "") == "1", points = {}, curves = {} }
      for tok in tostring(p[3] or ""):gmatch("[^|]+") do
        local vs, ts = tok:match("^%s*([%-%d%.eE]+)%s*@%s*([%-%d%.eE]+)%s*$")
        local v, t = tonumber(vs), tonumber(ts)
        if v and t then
          lane.points[#lane.points + 1] = { v = v, t = math.max(0, math.min(1, t)) }
        end
      end
      for tok in tostring(p[4] or ""):gmatch("[^,]+") do
        lane.curves[#lane.curves + 1] = math.max(0, math.min(ANIM_GRAPH_CURVE_LAST, math.floor(tonumber(tok) or 0)))
      end
      lane.curve_blends = {}
      if p[5] and tostring(p[5]) ~= "" then
        local bi = 1
        for tok in tostring(p[5]):gmatch("[^,]+") do
          local tt = tok:match("^%s*(.-)%s*$")
          if tt ~= "d" and tt ~= "D" and tt ~= "" then
            local bv = tonumber(tt)
            if bv then
              lane.curve_blends[bi] = math.max(-1, math.min(1, bv))
            end
          end
          bi = bi + 1
        end
      end
      if #lane.points >= 2 then
        table.sort(lane.points, function(a, b)
          return (a.t or 0) < (b.t or 0)
        end)
        lane.points[1].t = 0
        lane.points[#lane.points].t = 1
        out[key] = lane
      end
    end
  end
  return out
end

local function append_anim_auto_lane_eval(lines, pfx, key, tvar, lane, def_expr)
  local meta = ANIM_AUTO_META[key]
  local var = pfx .. "a_" .. key
  lines[#lines + 1] = string.format("  %s=%s;", var, def_expr)
  if not (meta and type(lane) == "table" and lane.enabled and type(lane.points) == "table" and #lane.points >= 2) then
    return var
  end
  for i = 1, #lane.points - 1 do
    local p0, p1 = lane.points[i], lane.points[i + 1]
    local t0 = math.max(0, math.min(1, tonumber(p0.t) or 0))
    local t1 = math.max(0, math.min(1, tonumber(p1.t) or 1))
    local dt = math.max(1e-6, t1 - t0)
    local v0 = math.max(meta.min, math.min(meta.max, tonumber(p0.v) or meta.min))
    local v1 = math.max(meta.min, math.min(meta.max, tonumber(p1.v) or meta.min))
    local u = pfx .. "u_" .. key
    local cmp = (i == (#lane.points - 1)) and "<=" or "<"
    local ce = anim_graph_seg_ease_expr(lane.curves and lane.curves[i] or 0, u, lane.curve_blends and lane.curve_blends[i])
    lines[#lines + 1] = string.format(
      "  ((%s >= %s) && (%s %s %s)) ? (%s=max(0,min(1,(%s-%s)/%s)); %s=%s+(%s-%s)*(%s);) : 0;",
      tvar, fmt_eel_num(t0), tvar, cmp, fmt_eel_num(t1),
      u, tvar, fmt_eel_num(t0), fmt_eel_num(dt),
      var, fmt_eel_num(v0), fmt_eel_num(v1), fmt_eel_num(v0), ce
    )
  end
  lines[#lines + 1] = string.format("  %s=max(%s,min(%s,%s));", var, fmt_eel_num(meta.min), fmt_eel_num(meta.max), var)
  if meta.integer then
    lines[#lines + 1] = string.format("  %s=floor(%s+0.5);", var, var)
  end
  return var
end

local function anim_preset_key(name)
  local n = tostring(name or ""):match("^%s*(.-)%s*$")
  local safe = n:gsub("[^%w%-_]", "_")
  if safe == "" then
    safe = "_"
  end
  return "ANIM_PRESET_DATA_" .. safe
end

local function split_sep31(s)
  local out = {}
  if type(s) ~= "string" or s == "" then
    return out
  end
  for tok in s:gmatch("[^\031]+") do
    out[#out + 1] = tok
  end
  return out
end

local function parse_anim_preset_blob(blob)
  local t = split_sep31(blob)
  if #t < 20 then
    return nil
  end
  local function b(v, def)
    if v == nil then return def end
    return tostring(v) == "1"
  end
  local function n(v, def, mn, mx)
    local x = tonumber(v)
    if x == nil then x = def end
    if mn ~= nil and x < mn then x = mn end
    if mx ~= nil and x > mx then x = mx end
    return x
  end
  local function ni(v, def, mn, mx)
    return math.floor(n(v, def, mn, mx) + 0.5)
  end
  local in_use_graph = b(t[46], false)
  local out_use_graph = b(t[47], false)
  local in_graph = t[49]
  local out_graph = t[50]
  if in_graph == nil and out_graph == nil then
    in_use_graph = false
    out_use_graph = false
    in_graph = t[47]
    out_graph = t[48]
  end
  local types_are_v3 = (tonumber(t[#t] or "") == 3)
  local function preset_in_type()
    local raw = tonumber(t[3]) or ANIM_TYPE_FADE
    if types_are_v3 then
      return math.max(ANIM_TYPE_NONE, math.min(ANIM_TYPE_LAST, math.floor(raw + 0.5)))
    end
    return math.max(ANIM_TYPE_NONE, math.min(ANIM_TYPE_LAST, migrate_anim_type_compact_to_v3(raw)))
  end
  local function preset_out_type()
    local raw = tonumber(t[17]) or ANIM_TYPE_FADE
    if types_are_v3 then
      return math.max(ANIM_TYPE_NONE, math.min(ANIM_TYPE_LAST, math.floor(raw + 0.5)))
    end
    return math.max(ANIM_TYPE_NONE, math.min(ANIM_TYPE_LAST, migrate_anim_type_compact_to_v3(raw)))
  end
  return {
    in_on = b(t[2], false),
    in_type = preset_in_type(),
    in_curve = ni(t[4], ANIM_CURVE_LINEAR, ANIM_CURVE_LINEAR, ANIM_CURVE_ELASTIC),
    in_dur = n(t[5], 0.12, 0, 2.0),
    in_amp = n(t[6], 1, 0, 3.0),
    in_bounce = n(t[7], 0.7, 0, 2.0),
    in_motion = n(t[8], 1, 0, 3.0),
    in_wiggle = n(t[9], 1, 0, 3.0),
    in_scale = n(t[10], 0, -1.0, 2.0),
    in_fade = n(t[11], 0, 0, 1.0),
    in_blur = n(t[12], 0, 0, 3.0),
    in_ghost = n(t[13], 1, 0, 2.0),
    in_dupes = ni(t[14], 3, 1, ANIM_MAX_DUPES),
    in_dir = n(t[15], 90, -180, 180),
    out_on = b(t[16], false),
    out_type = preset_out_type(),
    out_curve = ni(t[18], ANIM_CURVE_LINEAR, ANIM_CURVE_LINEAR, ANIM_CURVE_ELASTIC),
    out_dur = n(t[19], 0.12, 0, 2.0),
    out_amp = n(t[20], 1, 0, 3.0),
    out_bounce = n(t[21], 0.7, 0, 2.0),
    out_motion = n(t[22], 1, 0, 3.0),
    out_wiggle = n(t[23], 1, 0, 3.0),
    out_scale = n(t[24], 0, -1.0, 2.0),
    out_fade = n(t[25], 0, 0, 1.0),
    out_blur = n(t[26], 0, 0, 3.0),
    out_ghost = n(t[27], 1, 0, 2.0),
    out_dupes = ni(t[28], 3, 1, ANIM_MAX_DUPES),
    out_dir = n(t[29], 90, -180, 180),
    in_twist = n(t[44], 0, -720, 720),
    out_twist = n(t[45], 0, -720, 720),
    in_use_graph = in_use_graph,
    out_use_graph = out_use_graph,
    in_graph = in_graph,
    out_graph = out_graph,
  }
end

local function append_anim_graph_path_eel(lines, pfx, tvar, graph)
  if type(graph) ~= "table" or type(graph.points) ~= "table" or #graph.points < 2 then
    return false
  end
  local pts = graph.points
  local cvs = graph.curves or {}
  local gx = pfx .. "pgx"
  local gy = pfx .. "pgy"
  local gu = pfx .. "pgu"
  lines[#lines + 1] = string.format("  %s=%s; %s=%s;", gx, fmt_eel_num(pts[1].x or 0), gy, fmt_eel_num(pts[1].y or 0))
  for i = 1, #pts - 1 do
    local p0, p1 = pts[i], pts[i + 1]
    local t0 = math.max(0, math.min(1, tonumber(p0.t) or 0))
    local t1 = math.max(0, math.min(1, tonumber(p1.t) or 1))
    local dt = math.max(1e-6, t1 - t0)
    local cmp = (i == (#pts - 1)) and "<=" or "<"
    local ce = anim_graph_seg_ease_expr(cvs[i] or ANIM_GRAPH_CURVE_LINEAR, gu, graph.seg_blends and graph.seg_blends[i])
    lines[#lines + 1] = string.format(
      "  ((%s >= %s) && (%s %s %s)) ? (%s=max(0,min(1,(%s-%s)/%s)); %s=%s+(%s-%s)*(%s); %s=%s+(%s-%s)*(%s);) : 0;",
      tvar,
      fmt_eel_num(t0),
      tvar,
      cmp,
      fmt_eel_num(t1),
      gu,
      tvar,
      fmt_eel_num(t0),
      fmt_eel_num(dt),
      gx,
      fmt_eel_num(p0.x or 0),
      fmt_eel_num(p1.x or 0),
      fmt_eel_num(p0.x or 0),
      ce,
      gy,
      fmt_eel_num(p0.y or 0),
      fmt_eel_num(p1.y or 0),
      fmt_eel_num(p0.y or 0),
      ce
    )
  end
  return true
end

local function append_anim_ops(
  lines,
  pfx,
  typ,
  evar,
  ivar,
  is_entry,
  ampvar,
  bouncevar,
  motionvar,
  wigglevar,
  ghostvar,
  dupesvar,
  dirx,
  diry,
  scalevar,
  fadevar,
  blurvar,
  graph,
  dirdegvar,
  wipe_mask_offset,
  graph_path_t_in_override,
  graph_path_t_out_override
)
  if typ == ANIM_TYPE_NONE then
    return
  end
  if typ == ANIM_TYPE_FADE then
    if is_entry then
      lines[#lines + 1] = string.format("  %sa*=(1-%s*%s);", pfx, ampvar, ivar)
    else
      lines[#lines + 1] = string.format("  %sa*=(1-%s*%s);", pfx, ampvar, evar)
    end
    return
  end
  if typ == ANIM_TYPE_ZOOM_IN then
    if is_entry then
      lines[#lines + 1] = string.format("  %ss*=(1-0.3*%s*%s);", pfx, ampvar, ivar)
    else
      lines[#lines + 1] = string.format("  %ss*=(1+0.25*%s*%s);", pfx, ampvar, evar)
    end
    return
  end
  if typ == ANIM_TYPE_ZOOM_OUT then
    if is_entry then
      lines[#lines + 1] = string.format("  %ss*=(1+0.25*%s*%s);", pfx, ampvar, ivar)
    else
      lines[#lines + 1] = string.format("  %ss*=(1-0.35*%s*%s);", pfx, ampvar, evar)
    end
    return
  end
  if typ == ANIM_TYPE_SLIDE_LEFT then
    lines[#lines + 1] =
      string.format("  %sdx+=((%s)*project_w*0.12)*%s*%s*%s;", pfx, is_entry and "-1" or "-1", is_entry and ivar or evar, ampvar, motionvar)
    return
  end
  if typ == ANIM_TYPE_SLIDE_RIGHT then
    lines[#lines + 1] =
      string.format("  %sdx+=((%s)*project_w*0.12)*%s*%s*%s;", pfx, is_entry and "1" or "1", is_entry and ivar or evar, ampvar, motionvar)
    return
  end
  if typ == ANIM_TYPE_SLIDE_UP then
    lines[#lines + 1] =
      string.format("  %sdy+=((%s)*project_h*0.10)*%s*%s*%s;", pfx, is_entry and "-1" or "-1", is_entry and ivar or evar, ampvar, motionvar)
    return
  end
  if typ == ANIM_TYPE_SLIDE_DOWN then
    lines[#lines + 1] =
      string.format("  %sdy+=((%s)*project_h*0.10)*%s*%s*%s;", pfx, is_entry and "1" or "1", is_entry and ivar or evar, ampvar, motionvar)
    return
  end
  if typ == ANIM_TYPE_WHIP_LEFT then
    local t = is_entry and ("(" .. ivar .. "*" .. ivar .. ")") or ("(" .. evar .. "*" .. evar .. ")")
    lines[#lines + 1] = string.format("  %sdx+=-1*project_w*0.24*%s*%s*%s;", pfx, t, ampvar, motionvar)
    if not is_entry then
      lines[#lines + 1] = string.format("  %sa*=(1-0.4*%s*%s);", pfx, ampvar, evar)
    end
    return
  end
  if typ == ANIM_TYPE_WHIP_RIGHT then
    local t = is_entry and ("(" .. ivar .. "*" .. ivar .. ")") or ("(" .. evar .. "*" .. evar .. ")")
    lines[#lines + 1] = string.format("  %sdx+=project_w*0.24*%s*%s*%s;", pfx, t, ampvar, motionvar)
    if not is_entry then
      lines[#lines + 1] = string.format("  %sa*=(1-0.4*%s*%s);", pfx, ampvar, evar)
    end
    return
  end
  if typ == ANIM_TYPE_POP then
    local t = is_entry and ivar or evar
    lines[#lines + 1] = string.format("  %ss*=(1+0.55*%s*%s);", pfx, ampvar, t)
    lines[#lines + 1] = string.format("  %sa*=(1-0.25*%s*%s);", pfx, ampvar, t)
    return
  end
  if typ == ANIM_TYPE_PUNCH then
    local p = is_entry and evar or evar
    local t = is_entry and ivar or evar
    lines[#lines + 1] = string.format("  %ss*=(1+0.22*%s*sin(%s*12.56637*%s)*%s);", pfx, ampvar, p, wigglevar, t)
    return
  end
  if typ == ANIM_TYPE_SQUASH then
    local t = is_entry and ivar or evar
    -- Blend X/Y squash by cos²/sin² of direction so diagonals compress both axes;
    -- dominant axis scales by σ≈max(0.05,1-0.72*amp*t), other axis stays 1.
    local c = tonumber(dirx) or 1
    local s = tonumber(diry) or 0
    local ax = math.abs(c)
    local ay = math.abs(s)
    local nrm = ax * ax + ay * ay
    if nrm < 1e-24 then
      ax = 1
      ay = 0
      nrm = 1
    end
    local wx = ax * ax / nrm
    local wy = ay * ay / nrm
    local squ_sig = pfx .. "sqsg"
    lines[#lines + 1] = string.format(
      "  %s=max(0.05,1-0.72*%s*%s); %ssx*=((%.17g)+(%.17g*%s)); %ssy*=((%.17g)+(%.17g*%s));",
      squ_sig,
      ampvar,
      t,
      pfx,
      1 - wx,
      wx,
      squ_sig,
      pfx,
      1 - wy,
      wy,
      squ_sig
    )
    return
  end
  if typ == ANIM_TYPE_STRETCH then
    local t = is_entry and ivar or evar
    local c = tonumber(dirx) or 1
    local s = tonumber(diry) or 0
    local ax = math.abs(c)
    local ay = math.abs(s)
    local nrm = ax * ax + ay * ay
    if nrm < 1e-24 then
      ax = 1
      ay = 0
      nrm = 1
    end
    local wx = ax * ax / nrm
    local wy = ay * ay / nrm
    local st_sig = pfx .. "stsg"
    lines[#lines + 1] = string.format(
      "  %s=(1+0.72*%s*%s); %ssx*=((%.17g)+(%.17g*%s)); %ssy*=((%.17g)+(%.17g*%s));",
      st_sig,
      ampvar,
      t,
      pfx,
      1 - wx,
      wx,
      st_sig,
      pfx,
      1 - wy,
      wy,
      st_sig
    )
    return
  end
  if typ == ANIM_TYPE_DROP_BOUNCE then
    local p = is_entry and evar or evar
    local t = is_entry and ivar or evar
    -- Bounce scales overshoot wobble; phase uses (0.35+0.65*wiggle) so wiggle=0 still wobbles.
    lines[#lines + 1] = string.format(
      "  %sdy+=(-project_h*0.20*%s*%s*%s)+(project_h*(0.01+0.11*%s)*sin(%s*18.84956*(0.35+0.65*%s))*%s*%s);",
      pfx,
      ampvar,
      t,
      motionvar,
      bouncevar,
      p,
      wigglevar,
      ampvar,
      t
    )
    return
  end
  if typ == ANIM_TYPE_RISE_BOUNCE then
    local p = is_entry and evar or evar
    local t = is_entry and ivar or evar
    lines[#lines + 1] = string.format(
      "  %sdy+=(project_h*0.20*%s*%s*%s)+(-project_h*(0.01+0.11*%s)*sin(%s*18.84956*(0.35+0.65*%s))*%s*%s);",
      pfx,
      ampvar,
      t,
      motionvar,
      bouncevar,
      p,
      wigglevar,
      ampvar,
      t
    )
    return
  end
  if typ == ANIM_TYPE_DRIFT_LEFT then
    local p = is_entry and evar or evar
    local t = is_entry and ivar or evar
    lines[#lines + 1] = string.format("  %sdx+=-project_w*0.10*%s*%s*%s;", pfx, ampvar, t, motionvar)
    lines[#lines + 1] = string.format("  %sdy+=project_h*0.025*sin(%s*6.28318*%s)*%s*%s*%s;", pfx, p, wigglevar, ampvar, t, motionvar)
    return
  end
  if typ == ANIM_TYPE_DRIFT_RIGHT then
    local p = is_entry and evar or evar
    local t = is_entry and ivar or evar
    lines[#lines + 1] = string.format("  %sdx+=project_w*0.10*%s*%s*%s;", pfx, ampvar, t, motionvar)
    lines[#lines + 1] = string.format("  %sdy+=project_h*0.025*sin(%s*6.28318*%s)*%s*%s*%s;", pfx, p, wigglevar, ampvar, t, motionvar)
    return
  end
  if typ == ANIM_TYPE_SHAKE then
    local p = is_entry and evar or evar
    local t = is_entry and ivar or evar
    lines[#lines + 1] = string.format("  %sdx+=project_w*0.018*sin(%s*50.26548*%s)*%s*%s*%s;", pfx, p, wigglevar, ampvar, t, motionvar)
    return
  end
  if typ == ANIM_TYPE_JITTER then
    local p = is_entry and evar or evar
    local t = is_entry and ivar or evar
    lines[#lines + 1] = string.format("  %sdx+=project_w*0.012*sin(%s*91.10618*%s)*%s*%s*%s;", pfx, p, wigglevar, ampvar, t, motionvar)
    lines[#lines + 1] = string.format("  %sdy+=project_h*0.012*cos(%s*79.16814*%s)*%s*%s*%s;", pfx, p, wigglevar, ampvar, t, motionvar)
    return
  end
  if typ == ANIM_TYPE_WAVE then
    local p = is_entry and evar or evar
    local t = is_entry and ivar or evar
    lines[#lines + 1] = string.format("  %sdy+=project_h*0.05*sin(%s*6.28318*%s)*%s*%s*%s;", pfx, p, wigglevar, ampvar, t, motionvar)
    return
  end
  if typ == ANIM_TYPE_ORBIT then
    local p = is_entry and evar or evar
    local t = is_entry and ivar or evar
    lines[#lines + 1] = string.format("  %sdx+=project_w*0.06*cos(%s*6.28318*%s)*%s*%s*%s;", pfx, p, wigglevar, ampvar, t, motionvar)
    lines[#lines + 1] = string.format("  %sdy+=project_h*0.06*sin(%s*6.28318*%s)*%s*%s*%s;", pfx, p, wigglevar, ampvar, t, motionvar)
    return
  end
  if typ == ANIM_TYPE_SPIRAL then
    local p = is_entry and evar or evar
    local t = is_entry and ivar or evar
    lines[#lines + 1] = string.format("  %sdx+=project_w*0.12*cos(%s*12.56637*%s)*%s*%s*%s;", pfx, p, wigglevar, ampvar, t, motionvar)
    lines[#lines + 1] = string.format("  %sdy+=project_h*0.12*sin(%s*12.56637*%s)*%s*%s*%s;", pfx, p, wigglevar, ampvar, t, motionvar)
    lines[#lines + 1] = string.format("  %ss*=(1+0.18*%s*%s);", pfx, ampvar, t)
    return
  end
  if typ == ANIM_TYPE_STAMP then
    local t = is_entry and ivar or evar
    lines[#lines + 1] = string.format("  %ss*=(1+0.75*%s*%s*%s);", pfx, ampvar, t, t)
    lines[#lines + 1] = string.format("  %sa*=(1-0.20*%s*%s);", pfx, ampvar, t)
    return
  end
  if typ == ANIM_TYPE_ECHO_TRAIL then
    local p = is_entry and evar or evar
    local t = is_entry and ivar or evar
    lines[#lines + 1] = string.format("  %sdx+=project_w*0.055*sin(%s*9.42477*%s)*%s*%s*%s;", pfx, p, wigglevar, ampvar, t, motionvar)
    lines[#lines + 1] = string.format("  %ss*=(1+0.12*%s*%s);", pfx, ampvar, t)
    lines[#lines + 1] = string.format("  %sa*=(1-0.30*%s*%s);", pfx, ampvar, t)
    for i = 1, ANIM_MAX_DUPES do
      local idx = tostring(i)
      local alpha = fmt_eel_num(0.42 / (i ^ 0.55))
      local xmul = fmt_eel_num(-0.03 * i)
      local ymul = fmt_eel_num(0.006 * i)
      local phase = fmt_eel_num((i - 1) * 0.785398)
      lines[#lines + 1] = string.format(
        "  %sg%sa=((%s)>=%d?1:0)*%s*%s*%s*%s; %sg%sx=project_w*%s*%s*%s; %sg%sy=project_h*%s*sin(%s*6.28318*%s+%s)*%s;",
        pfx,
        idx,
        dupesvar,
        i,
        alpha,
        ampvar,
        t,
        ghostvar,
        pfx,
        idx,
        xmul,
        ampvar,
        motionvar,
        pfx,
        idx,
        ymul,
        p,
        wigglevar,
        phase,
        motionvar
      )
    end
    return
  end
  if typ == ANIM_TYPE_CLONE_BURST then
    local p = is_entry and evar or evar
    local t = is_entry and ivar or evar
    lines[#lines + 1] = string.format("  %sdx+=project_w*0.075*sin(%s*18.84956*%s)*%s*%s*%s;", pfx, p, wigglevar, ampvar, t, motionvar)
    lines[#lines + 1] = string.format("  %sdy+=project_h*0.055*cos(%s*12.56637*%s)*%s*%s*%s;", pfx, p, wigglevar, ampvar, t, motionvar)
    lines[#lines + 1] = string.format("  %ss*=(1+0.20*%s*%s);", pfx, ampvar, t)
    lines[#lines + 1] = string.format("  %sa*=(1-0.35*%s*%s);", pfx, ampvar, t)
    for i = 1, ANIM_MAX_DUPES do
      local idx = tostring(i)
      local phase = fmt_eel_num((i - 1) * 6.283185307179586 / ANIM_MAX_DUPES)
      local alpha = fmt_eel_num(0.34 / (i ^ 0.32))
      local radius = fmt_eel_num(0.07 - (i - 1) * 0.0035)
      lines[#lines + 1] = string.format(
        "  %sg%sa=((%s)>=%d?1:0)*%s*%s*%s*%s; %sg%sx=project_w*%s*cos(%s*6.28318*%s+%s)*%s*%s; %sg%sy=project_h*%s*sin(%s*6.28318*%s+%s)*%s*%s;",
        pfx,
        idx,
        dupesvar,
        i,
        alpha,
        ampvar,
        t,
        ghostvar,
        pfx,
        idx,
        radius,
        p,
        wigglevar,
        phase,
        t,
        motionvar,
        pfx,
        idx,
        radius,
        p,
        wigglevar,
        phase,
        t,
        motionvar
      )
    end
    return
  end
  if typ == ANIM_TYPE_CUSTOM then
    local p = is_entry and evar or evar
    local t = is_entry and ivar or evar
    local sx, sy, px, py
    if type(dirdegvar) == "string" and dirdegvar ~= "" then
      local ang = "((" .. dirdegvar .. ")*0.017453292519943295)"
      sx = "cos" .. ang
      sy = "sin" .. ang
      px = "(-(" .. sy .. "))"
      py = sx
    else
      sx = fmt_eel_num(tonumber(dirx) or 0)
      sy = fmt_eel_num(tonumber(diry) or 1)
      px = fmt_eel_num(-(tonumber(diry) or 1))
      py = fmt_eel_num(tonumber(dirx) or 0)
    end
    local path_t_expr = t
    if is_entry then
      if type(graph_path_t_in_override) == "string" and graph_path_t_in_override ~= "" then
        path_t_expr = graph_path_t_in_override
      end
    elseif type(graph_path_t_out_override) == "string" and graph_path_t_out_override ~= "" then
      path_t_expr = graph_path_t_out_override
    end
    local has_graph = append_anim_graph_path_eel(lines, pfx, path_t_expr, graph)
    if has_graph then
      lines[#lines + 1] = string.format("  %sdx+=project_w*0.22*%spgx*%s*%s;", pfx, pfx, ampvar, motionvar)
      lines[#lines + 1] = string.format("  %sdy+=project_h*0.22*%spgy*%s*%s;", pfx, pfx, ampvar, motionvar)
    else
      lines[#lines + 1] = string.format("  %sdx+=project_w*0.16*%s*%s*%s*%s;", pfx, sx, ampvar, t, motionvar)
      lines[#lines + 1] = string.format("  %sdy+=project_h*0.16*%s*%s*%s*%s;", pfx, sy, ampvar, t, motionvar)
    end
    lines[#lines + 1] = string.format("  %sdx+=project_w*0.025*%s*sin(%s*6.28318*%s)*%s*%s*%s;", pfx, px, p, wigglevar, ampvar, t, motionvar)
    lines[#lines + 1] = string.format("  %sdy+=project_h*0.025*%s*sin(%s*6.28318*%s)*%s*%s*%s;", pfx, py, p, wigglevar, ampvar, t, motionvar)
    lines[#lines + 1] = string.format("  %sdx+=project_w*0.045*%s*sin(%s*18.84956*%s)*%s*%s*%s;", pfx, sx, p, wigglevar, ampvar, t, bouncevar)
    lines[#lines + 1] = string.format("  %sdy+=project_h*0.045*%s*sin(%s*18.84956*%s)*%s*%s*%s;", pfx, sy, p, wigglevar, ampvar, t, bouncevar)
    lines[#lines + 1] = string.format("  %ss*=(1+(%s*%s*%s)+(0.18*%s*sin(%s*12.56637*%s)*%s));", pfx, scalevar, ampvar, t, ampvar, p, wigglevar, t)
    lines[#lines + 1] = string.format("  %sa*=(1-%s*%s*%s);", pfx, fadevar, ampvar, t)
    lines[#lines + 1] = string.format("  %sb+=8*%s*%s*%s;", pfx, blurvar, ampvar, t)
    for i = 1, ANIM_MAX_DUPES do
      local idx = tostring(i)
      local k = fmt_eel_num(i / ANIM_MAX_DUPES)
      local alpha = fmt_eel_num(0.36 / (i ^ 0.45))
      lines[#lines + 1] = string.format(
        "  %sg%sa=((%s)>=%d?1:0)*%s*%s*%s*%s; %sg%sx=project_w*0.16*%s*%s*%s*%s + project_w*0.018*%s*sin(%s*6.28318*%s+%s)*%s; %sg%sy=project_h*0.16*%s*%s*%s*%s + project_h*0.018*%s*sin(%s*6.28318*%s+%s)*%s;",
        pfx,
        idx,
        dupesvar,
        i,
        alpha,
        ampvar,
        t,
        ghostvar,
        pfx,
        idx,
        has_graph and (pfx .. "pgx") or sx,
        ampvar,
        motionvar,
        k,
        px,
        p,
        wigglevar,
        k,
        motionvar,
        pfx,
        idx,
        has_graph and (pfx .. "pgy") or sy,
        ampvar,
        motionvar,
        k,
        py,
        p,
        wigglevar,
        k,
        motionvar
      )
    end
    return
  end
  if typ == ANIM_TYPE_BLUR then
    local t = is_entry and ivar or evar
    lines[#lines + 1] = string.format("  %sb+=8*max(0.2,%s)*%s*%s;", pfx, blurvar, ampvar, t)
    return
  end
  if typ == ANIM_TYPE_WIPE_REVEAL then
    lines[#lines + 1] = string.format(
      "  %smk=1; %sm=max(0,min(1,(%s)*2)); %smx=%s; %smy=%s; %smo=wipeMaskOffset;",
      pfx,
      pfx,
      is_entry and evar or ivar,
      pfx,
      dirx,
      pfx,
      diry,
      pfx
    )
    return
  end
end

local function append_anim_eel(lines, pfx, t0_expr, t1_expr, anim)
  if type(anim) ~= "table" then
    return
  end
  local in_on = anim.in_on and true or false
  local out_on = anim.out_on and true or false
  local in_dur = math.max(0, tonumber(anim.in_dur) or 0)
  local out_dur = math.max(0, tonumber(anim.out_dur) or 0)
  local in_type = math.floor(tonumber(anim.in_type) or 0)
  local out_type = math.floor(tonumber(anim.out_type) or 0)
  local in_curve = math.floor(tonumber(anim.in_curve) or 0)
  local out_curve = math.floor(tonumber(anim.out_curve) or 0)
  local in_amp = math.max(0, math.min(3.0, tonumber(anim.in_amp) or 1))
  local out_amp = math.max(0, math.min(3.0, tonumber(anim.out_amp) or 1))
  local in_bounce = fmt_eel_num(math.max(0, math.min(2.0, tonumber(anim.in_bounce or anim.bounce) or 0.7)))
  local in_motion = fmt_eel_num(math.max(0, math.min(3.0, tonumber(anim.in_motion or anim.motion) or 1)))
  local in_wiggle = fmt_eel_num(math.max(0, math.min(3.0, tonumber(anim.in_wiggle or anim.wiggle) or 1)))
  local in_scale = fmt_eel_num(math.max(-1.0, math.min(2.0, tonumber(anim.in_scale or anim.scale) or 0)))
  local in_fade = fmt_eel_num(math.max(0, math.min(1.0, tonumber(anim.in_fade or anim.fade) or 0)))
  local in_blur = fmt_eel_num(math.max(0, math.min(3.0, tonumber(anim.in_blur or anim.blur) or 0)))
  local in_ghost = fmt_eel_num(math.max(0, math.min(2.0, tonumber(anim.in_ghost or anim.ghost) or 1)))
  local in_dupes = fmt_eel_num(math.max(1, math.min(ANIM_MAX_DUPES, math.floor(tonumber(anim.in_dupes or anim.dupes) or 3))))
  local in_dir = math.rad(math.max(-180, math.min(180, tonumber(anim.in_dir or anim.dir) or 90)))
  local out_bounce = fmt_eel_num(math.max(0, math.min(2.0, tonumber(anim.out_bounce or anim.bounce) or 0.7)))
  local out_motion = fmt_eel_num(math.max(0, math.min(3.0, tonumber(anim.out_motion or anim.motion) or 1)))
  local out_wiggle = fmt_eel_num(math.max(0, math.min(3.0, tonumber(anim.out_wiggle or anim.wiggle) or 1)))
  local out_scale = fmt_eel_num(math.max(-1.0, math.min(2.0, tonumber(anim.out_scale or anim.scale) or 0)))
  local out_fade = fmt_eel_num(math.max(0, math.min(1.0, tonumber(anim.out_fade or anim.fade) or 0)))
  local out_blur = fmt_eel_num(math.max(0, math.min(3.0, tonumber(anim.out_blur or anim.blur) or 0)))
  local out_ghost = fmt_eel_num(math.max(0, math.min(2.0, tonumber(anim.out_ghost or anim.ghost) or 1)))
  local out_dupes = fmt_eel_num(math.max(1, math.min(ANIM_MAX_DUPES, math.floor(tonumber(anim.out_dupes or anim.dupes) or 3))))
  local out_dir = math.rad(math.max(-180, math.min(180, tonumber(anim.out_dir or anim.dir) or 90)))
  local twist_in = math.max(-720, math.min(720, tonumber(anim.in_twist) or 0))
  local twist_out = math.max(-720, math.min(720, tonumber(anim.out_twist) or 0))
  local wipe_mask_offset = fmt_eel_num(math.max(-300, math.min(300, tonumber(anim.wipe_mask_offset) or 0)))
  local in_graph = (anim.in_use_graph and true or false) and parse_anim_graph_blob(anim.in_graph) or nil
  local out_graph = (anim.out_use_graph and true or false) and parse_anim_graph_blob(anim.out_graph) or nil
  local in_auto = parse_anim_auto_blob(anim.in_auto_blob)
  local out_auto = parse_anim_auto_blob(anim.out_auto_blob)
  local gwu_var = pfx .. "gwu"
  local in_use_path_word =
    (anim.in_graph_word_span and true or false)
    and (anim.in_use_graph and true or false)
    and in_graph ~= nil
    and in_type == ANIM_TYPE_CUSTOM
  local out_use_path_word =
    (anim.out_graph_word_span and true or false)
    and (anim.out_use_graph and true or false)
    and out_graph ~= nil
    and out_type == ANIM_TYPE_CUSTOM
  if in_use_path_word or out_use_path_word then
    lines[#lines + 1] = string.format(
      "  %s=max(0,min(1,(src-(%s))/max(1e-11,(%s)-(%s))));",
      gwu_var,
      t0_expr,
      t1_expr,
      t0_expr
    )
  end
  local graph_t_in_ov = (in_use_path_word and gwu_var) or nil
  local graph_t_out_ov = (out_use_path_word and gwu_var) or nil
  do
    local init = {
      string.format("  %sa=1; %ss=1; %ssx=1; %ssy=1; %sdx=0; %sdy=0; %sb=0; %sr=0; %smk=0; %sm=1; %smx=1; %smy=0; %smo=0;", pfx, pfx, pfx, pfx, pfx, pfx, pfx, pfx, pfx, pfx, pfx, pfx, pfx)
    }
    for i = 1, ANIM_MAX_DUPES do
      init[#init + 1] = string.format(" %sg%da=0; %sg%dx=0; %sg%dy=0;", pfx, i, pfx, i, pfx, i)
    end
    lines[#lines + 1] = table.concat(init, "")
  end
  local has_in = in_on and in_dur > 1e-6 and in_type ~= ANIM_TYPE_NONE
  local has_out = out_on and out_dur > 1e-6 and out_type ~= ANIM_TYPE_NONE
  if not has_in and not has_out and math.abs(twist_in) < 1e-8 and math.abs(twist_out) < 1e-8 then
    return
  end
  if has_in then
    local p = pfx .. "pin"
    local e = pfx .. "ein"
    local iv = pfx .. "iinv"
    local amp = pfx .. "iamp"
    lines[#lines + 1] = string.format(
      "  %s=min(1,max(0,(src-%s)/%s)); %s=%s; %s=1-%s; %s=%s;",
      p,
      t0_expr,
      fmt_eel_num(in_dur),
      e,
      anim_curve_expr(in_curve, p, in_bounce),
      iv,
      e,
      amp,
      fmt_eel_num(in_amp)
    )
    local mv = append_anim_auto_lane_eval(lines, pfx, "motion", iv, in_auto.motion, in_motion)
    local wv = append_anim_auto_lane_eval(lines, pfx, "wiggle", iv, in_auto.wiggle, in_wiggle)
    local sv = append_anim_auto_lane_eval(lines, pfx, "scale", iv, in_auto.scale, in_scale)
    local fv = append_anim_auto_lane_eval(lines, pfx, "fade", iv, in_auto.fade, in_fade)
    local bv = append_anim_auto_lane_eval(lines, pfx, "blur", iv, in_auto.blur, in_blur)
    local bnc = append_anim_auto_lane_eval(lines, pfx, "bounce", iv, in_auto.bounce, in_bounce)
    local gh = append_anim_auto_lane_eval(lines, pfx, "ghost", iv, in_auto.ghost, in_ghost)
    local dp = append_anim_auto_lane_eval(lines, pfx, "dupes", iv, in_auto.dupes, in_dupes)
    local dirv = append_anim_auto_lane_eval(lines, pfx, "dir", iv, in_auto.dir, fmt_eel_num(math.deg(in_dir)))
    local twv = append_anim_auto_lane_eval(lines, pfx, "twist", iv, in_auto.twist, fmt_eel_num(twist_in))
    append_anim_ops(
      lines,
      pfx,
      in_type,
      e,
      iv,
      true,
      amp,
      bnc,
      mv,
      wv,
      gh,
      dp,
      math.cos(in_dir),
      math.sin(in_dir),
      sv,
      fv,
      bv,
      in_graph,
      dirv,
      wipe_mask_offset,
      graph_t_in_ov,
      graph_t_out_ov
    )
    if math.abs(twist_in) > 1e-8 or (in_auto.twist and in_auto.twist.enabled) then
      lines[#lines + 1] = string.format("  %sr+=(%s*0.017453292519943295)*%s;", pfx, twv, iv)
    end
  elseif in_on and in_dur > 1e-6 and math.abs(twist_in) > 1e-8 then
    local p = pfx .. "pin"
    local e = pfx .. "ein"
    local iv = pfx .. "iinv"
    local amp = pfx .. "iamp"
    lines[#lines + 1] = string.format(
      "  %s=min(1,max(0,(src-%s)/%s)); %s=%s; %s=1-%s; %s=%s;",
      p, t0_expr, fmt_eel_num(in_dur), e, p, iv, e, amp, fmt_eel_num(in_amp)
    )
    lines[#lines + 1] = string.format("  %sr+=%s*%s;", pfx, fmt_eel_num(math.rad(twist_in)), iv)
  end
  if has_out then
    local p = pfx .. "pout"
    local e = pfx .. "eout"
    local iv = pfx .. "oinv"
    local amp = pfx .. "oamp"
    lines[#lines + 1] = string.format(
      "  %s=min(1,max(0,(src-(%s-%s))/%s)); %s=%s; %s=1-%s; %s=%s;",
      p,
      t1_expr,
      fmt_eel_num(out_dur),
      fmt_eel_num(out_dur),
      e,
      anim_curve_expr(out_curve, p, out_bounce),
      iv,
      e,
      amp,
      fmt_eel_num(out_amp)
    )
    local mv = append_anim_auto_lane_eval(lines, pfx, "motion", iv, out_auto.motion, out_motion)
    local wv = append_anim_auto_lane_eval(lines, pfx, "wiggle", iv, out_auto.wiggle, out_wiggle)
    local sv = append_anim_auto_lane_eval(lines, pfx, "scale", iv, out_auto.scale, out_scale)
    local fv = append_anim_auto_lane_eval(lines, pfx, "fade", iv, out_auto.fade, out_fade)
    local bv = append_anim_auto_lane_eval(lines, pfx, "blur", iv, out_auto.blur, out_blur)
    local bnc = append_anim_auto_lane_eval(lines, pfx, "bounce", iv, out_auto.bounce, out_bounce)
    local gh = append_anim_auto_lane_eval(lines, pfx, "ghost", iv, out_auto.ghost, out_ghost)
    local dp = append_anim_auto_lane_eval(lines, pfx, "dupes", iv, out_auto.dupes, out_dupes)
    local dirv = append_anim_auto_lane_eval(lines, pfx, "dir", iv, out_auto.dir, fmt_eel_num(math.deg(out_dir)))
    local twv = append_anim_auto_lane_eval(lines, pfx, "twist", iv, out_auto.twist, fmt_eel_num(twist_out))
    append_anim_ops(
      lines,
      pfx,
      out_type,
      e,
      iv,
      false,
      amp,
      bnc,
      mv,
      wv,
      gh,
      dp,
      math.cos(out_dir),
      math.sin(out_dir),
      sv,
      fv,
      bv,
      out_graph,
      dirv,
      wipe_mask_offset,
      graph_t_in_ov,
      graph_t_out_ov
    )
    if math.abs(twist_out) > 1e-8 or (out_auto.twist and out_auto.twist.enabled) then
      lines[#lines + 1] = string.format("  %sr+=(%s*0.017453292519943295)*%s;", pfx, twv, iv)
    end
  elseif out_on and out_dur > 1e-6 and math.abs(twist_out) > 1e-8 then
    local p = pfx .. "pout"
    local e = pfx .. "eout"
    local iv = pfx .. "oinv"
    local amp = pfx .. "oamp"
    lines[#lines + 1] = string.format(
      "  %s=min(1,max(0,(src-(%s-%s))/%s)); %s=%s; %s=1-%s; %s=%s;",
      p, t1_expr, fmt_eel_num(out_dur), fmt_eel_num(out_dur), e, p, iv, e, amp, fmt_eel_num(out_amp)
    )
    lines[#lines + 1] = string.format("  %sr+=%s*%s;", pfx, fmt_eel_num(math.rad(twist_out)), iv)
  end
  lines[#lines + 1] = string.format("  %sa=max(0,min(1,%sa)); %ss=max(0.1,%ss);", pfx, pfx, pfx, pfx)
end

--- gfx_setfont: pass font as an EEL string literal. No `|` in VP CODE lines.
--- Latin UI fonts often have no CJK glyphs; these picks cover JP on typical macOS/Win/Linux installs.
local function default_vp_gfx_font()
  local os = r.GetOS() or ""
  if os:match("Win") then
    return "Meiryo"
  end
  if os:match("OSX") or os:match("macOS") or os:match("Darwin") then
    return "Hiragino Sans"
  end
  return "Noto Sans CJK JP"
end

local function text_has_cjk(s)
  if type(s) ~= "string" or s == "" or not (utf8 and utf8.codes) then
    return false
  end
  local ok, found = pcall(function()
    for _, cp in utf8.codes(s) do
      if
        (cp >= 0x3040 and cp <= 0x309F) -- Hiragana
        or (cp >= 0x30A0 and cp <= 0x30FF) -- Katakana
        or (cp >= 0x3400 and cp <= 0x4DBF) -- CJK Extension A
        or (cp >= 0x4E00 and cp <= 0x9FFF) -- CJK Unified Ideographs
        or (cp >= 0xF900 and cp <= 0xFAFF) -- CJK Compatibility Ideographs
        or (cp >= 0xFF66 and cp <= 0xFF9F) -- Halfwidth Katakana
      then
        return true
      end
    end
    return false
  end)
  return ok and found or false
end

local function rgb_eel_parts(rgb)
  rgb = math.max(0, math.min(0xFFFFFF, math.floor(tonumber(rgb) or 0xFFFFFF)))
  local rr = math.floor(rgb / 0x10000) % 0x100
  local gg = math.floor(rgb / 0x100) % 0x100
  local bb = rgb % 0x100
  return fmt_eel_num(rr / 255), fmt_eel_num(gg / 255), fmt_eel_num(bb / 255)
end

local function word_style_for(display_opts, wi)
  local styles = display_opts and display_opts.word_styles
  if type(styles) ~= "table" then
    return nil
  end
  local st = styles[wi]
  if type(st) ~= "table" then
    return nil
  end
  local anim_preset_name = tostring(st.anim_preset_name or ""):match("^%s*(.-)%s*$")
  local flags = math.max(0, math.floor(tonumber(st.flags) or 0))
  local font_name = trim_display_line(tostring(st.font_name or ""))
  if flags == 0 and st.text_color == nil and st.highlight_color == nil and anim_preset_name == "" and font_name == "" then
    return nil
  end
  return {
    flags = flags,
    anim_preset_name = anim_preset_name,
    font_name = font_name,
    text_color = tonumber(st.text_color),
    highlight_color = tonumber(st.highlight_color),
    pseudo_bold_copies = math.max(1, math.min(8, math.floor(tonumber(st.pseudo_bold_copies) or 2))),
    pseudo_bold_offset = math.max(0.25, math.min(6, tonumber(st.pseudo_bold_offset) or 1)),
    pseudo_slant = math.max(-12, math.min(12, tonumber(st.pseudo_slant) or 2)),
    shadow_dx = math.max(-20, math.min(20, tonumber(st.shadow_dx) or 2)),
    shadow_dy = math.max(-20, math.min(20, tonumber(st.shadow_dy) or 2)),
    shadow_alpha = math.max(0, math.min(1, tonumber(st.shadow_alpha) or 0.55)),
    underline_thick = math.max(1, math.min(12, tonumber(st.underline_thick) or 1)),
    underline_offset = math.max(-8, math.min(16, tonumber(st.underline_offset) or 1)),
    outline_thickness = math.max(1, math.min(12, math.floor(tonumber(st.outline_thickness) or 2))),
    outline_gap = math.max(0, math.min(24, math.floor(tonumber(st.outline_gap) or 0))),
    outline_color = (function()
      local c = tonumber(st.outline_color)
      if not c then
        return 0
      end
      return math.max(0, math.min(0xFFFFFF, math.floor(c)))
    end)(),
  }
end

--- Integer-pixel halo: per layer R = 1 + gap + layer, eight symmetric str_draws (cardinals + diagonals).
local function append_word_outline_halo_eel(add, text_expr, x_expr, y_expr, alpha_expr, or_, og, ob, gap_px, thick_px)
  gap_px = math.max(0, math.min(24, math.floor(tonumber(gap_px) or 0)))
  thick_px = math.max(1, math.min(12, math.floor(tonumber(thick_px) or 2)))
  local chunks = {}
  chunks[#chunks + 1] = string.format("gfx_set(%s,%s,%s,0.72*%s);", or_, og, ob, alpha_expr)
  for t = 0, thick_px - 1 do
    local R = 1 + gap_px + t
    chunks[#chunks + 1] = string.format(
      "gfx_str_draw(%s,(%s)-%d,%s); gfx_str_draw(%s,(%s)+%d,%s); gfx_str_draw(%s,%s,(%s)-%d); gfx_str_draw(%s,%s,(%s)+%d);",
      text_expr,
      x_expr,
      R,
      y_expr,
      text_expr,
      x_expr,
      R,
      y_expr,
      text_expr,
      x_expr,
      y_expr,
      R,
      text_expr,
      x_expr,
      y_expr,
      R
    )
    chunks[#chunks + 1] = string.format(
      "gfx_str_draw(%s,(%s)-%d,(%s)-%d); gfx_str_draw(%s,(%s)-%d,(%s)+%d); gfx_str_draw(%s,(%s)+%d,(%s)-%d); gfx_str_draw(%s,(%s)+%d,(%s)+%d);",
      text_expr,
      x_expr,
      R,
      y_expr,
      R,
      text_expr,
      x_expr,
      R,
      y_expr,
      R,
      text_expr,
      x_expr,
      R,
      y_expr,
      R,
      text_expr,
      x_expr,
      R,
      y_expr,
      R
    )
  end
  add(table.concat(chunks, " "))
end

--- One step of 8-connected binary dilation: additive blit of `src` plus 8 shifted copies into `dst`.
local function append_outline_dilate_step_eel(lines, src, dst)
  lines[#lines + 1] = string.format("  gfx_dest=%s; gfx_mode=0; gfx_set(0,0,0,0); gfx_fillrect(0,0,wxov_ps,wxov_ps); gfx_mode=1; gfx_a=1;", dst)
  local offs = { { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
  for i = 1, #offs do
    local o = offs[i]
    lines[#lines + 1] = string.format(
      "  gfx_blit(%s,1,%d,%d,wxov_ps,wxov_ps,0,0,wxov_ps,wxov_ps);",
      src,
      o[1],
      o[2]
    )
  end
  lines[#lines + 1] = "  gfx_mode=0; gfx_a=1;"
end

--- After chroma on wxov_spin (white glyph on transparent), build true outline ring (dilate − inner) and premult fill, composite back into wxov_spin.
local function append_outline_mask_post_eel(lines, or_, og, ob, tr, tg, tb, gap_px, thick_px)
  gap_px = math.max(0, math.min(24, math.floor(tonumber(gap_px) or 0)))
  thick_px = math.max(1, math.min(12, math.floor(tonumber(thick_px) or 1)))
  lines[#lines + 1] = "  wxov_ol0=max(0,floor(wxov_ol0+0.5))<1 ? gfx_img_alloc(wxov_ps,wxov_ps,1) : gfx_img_resize(wxov_ol0,wxov_ps,wxov_ps,1);"
  lines[#lines + 1] = "  wxov_ol1=max(0,floor(wxov_ol1+0.5))<1 ? gfx_img_alloc(wxov_ps,wxov_ps,1) : gfx_img_resize(wxov_ol1,wxov_ps,wxov_ps,1);"
  lines[#lines + 1] = "  wxov_ol2=max(0,floor(wxov_ol2+0.5))<1 ? gfx_img_alloc(wxov_ps,wxov_ps,1) : gfx_img_resize(wxov_ol2,wxov_ps,wxov_ps,1);"
  lines[#lines + 1] = "  wxov_ol3=max(0,floor(wxov_ol3+0.5))<1 ? gfx_img_alloc(wxov_ps,wxov_ps,1) : gfx_img_resize(wxov_ol3,wxov_ps,wxov_ps,1);"
  lines[#lines + 1] = "  gfx_dest=wxov_ol0; gfx_mode=0; gfx_set(0,0,0,0); gfx_fillrect(0,0,wxov_ps,wxov_ps); gfx_blit(wxov_spin,1,0,0,wxov_ps,wxov_ps,0,0,wxov_ps,wxov_ps);"
  lines[#lines + 1] = "  gfx_dest=wxov_ol3; gfx_mode=0; gfx_set(0,0,0,0); gfx_fillrect(0,0,wxov_ps,wxov_ps); gfx_blit(wxov_ol0,1,0,0,wxov_ps,wxov_ps,0,0,wxov_ps,wxov_ps);"
  local cur, nxt = "wxov_ol0", "wxov_ol1"
  for _ = 1, gap_px do
    append_outline_dilate_step_eel(lines, cur, nxt)
    cur, nxt = nxt, cur
  end
  lines[#lines + 1] = string.format(
    "  gfx_dest=wxov_ol2; gfx_mode=0; gfx_set(0,0,0,0); gfx_fillrect(0,0,wxov_ps,wxov_ps); gfx_blit(%s,1,0,0,wxov_ps,wxov_ps,0,0,wxov_ps,wxov_ps);",
    cur
  )
  for _ = 1, thick_px do
    append_outline_dilate_step_eel(lines, cur, nxt)
    cur, nxt = nxt, cur
  end
  local mbig = cur
  -- gfx_evalrect: first src -> sr/sg/sb/sa, second -> s2r/s2g/s2b/s2a. Ring uses outer−inner; fill recolors dest matte (see fill_code).
  local ring_code = string.format(
    "_m1=min(255,sa); _m2=min(255,s2a); a=max(0,_m1-_m2); (a<=0)?(r=0;g=0;b=0;a=0;):(r=%s*a; g=%s*a; b=%s*a;);",
    or_,
    og,
    ob
  )
  lines[#lines + 1] = "  gfx_dest=wxov_spin; gfx_mode=0; gfx_set(0,0,0,0); gfx_fillrect(0,0,wxov_ps,wxov_ps);"
  lines[#lines + 1] = '  gfx_evalrect(0,0,wxov_ps,wxov_ps,"'
    .. ring_code
    .. '",0,'
    .. mbig
    .. ',"",wxov_ol2);'
  -- Recolor glyph matte using dest pixel alpha (chroma output); avoid second-src eval quirks on blit+preset sa.
  local fill_code = string.format("na=a; r=%s*na; g=%s*na; b=%s*na; a=na;", tr, tg, tb)
  lines[#lines + 1] = "  gfx_dest=wxov_ol0; gfx_mode=0; gfx_set(0,0,0,0); gfx_fillrect(0,0,wxov_ps,wxov_ps); gfx_blit(wxov_ol3,1,0,0,wxov_ps,wxov_ps,0,0,wxov_ps,wxov_ps);"
  lines[#lines + 1] = '  gfx_evalrect(0,0,wxov_ps,wxov_ps,"' .. fill_code .. '",0);'
  lines[#lines + 1] = "  gfx_dest=wxov_spin; gfx_mode=0x10000; gfx_a=1; gfx_blit(wxov_ol0,1,0,0,wxov_ps,wxov_ps,0,0,wxov_ps,wxov_ps); gfx_mode=0; gfx_a=1;"
end

local function word_style_font_expr(fontn, st)
  local f = fontn or ""
  if st then
    local ow = trim_display_line(tostring(st.font_name or ""))
    if ow ~= "" then
      f = ow
    end
  end
  local flags = st and math.max(0, math.floor(tonumber(st.flags) or 0)) or 0
  if (flags & WSTYLE_BOLD) ~= 0 and (flags & WSTYLE_ITALIC) ~= 0 then
    f = f .. " Bold Italic"
  elseif (flags & WSTYLE_BOLD) ~= 0 then
    f = f .. " Bold"
  elseif (flags & WSTYLE_ITALIC) ~= 0 then
    f = f .. " Italic"
  end
  return '"' .. escape_eel_dq_string(f) .. '"'
end

local function word_style_font_expr_for_text(fontn, st, text)
  return word_style_font_expr(fontn, st)
end

local function replace_all_plain(s, old, new)
  if not s or old == nil or old == "" then
    return s
  end
  local out, pos = {}, 1
  while true do
    local i, j = s:find(old, pos, true)
    if not i then
      out[#out + 1] = s:sub(pos)
      return table.concat(out)
    end
    out[#out + 1] = s:sub(pos, i - 1)
    out[#out + 1] = new
    pos = j + 1
  end
end

local function replace_eel_expr_plain(s, old, new)
  if not s or old == nil or old == "" then
    return s
  end
  if old:match("^[A-Za-z_][A-Za-z0-9_]*$") then
    local pat = "%f[%w_]" .. old .. "%f[^%w_]"
    return (s:gsub(pat, new))
  end
  return replace_all_plain(s, old, new)
end

local function anim_cfg_needs_image_mask(anim)
  if type(anim) ~= "table" then
    return false
  end
  local in_type = math.floor(tonumber(anim.in_type) or 0)
  local out_type = math.floor(tonumber(anim.out_type) or 0)
  return (anim.in_on and (in_type == ANIM_TYPE_WIPE_REVEAL or in_type == ANIM_TYPE_SQUASH or in_type == ANIM_TYPE_STRETCH))
    or (anim.out_on and (out_type == ANIM_TYPE_WIPE_REVEAL or out_type == ANIM_TYPE_SQUASH or out_type == ANIM_TYPE_STRETCH))
end

local function append_styled_text_draw(lines, text_expr, x_expr, y_expr, w_expr, h_expr, alpha_expr, st, anim_pfx, rot_var, image_mask_fx)
  st = st or {}
  local flags = math.max(0, math.floor(tonumber(st.flags) or 0))
  local outline_on = (flags & WSTYLE_OUTLINE) ~= 0
  --- Morphological ring outline needs the green-screen spin buffer; skip offset str_draw "halo" in that path.
  local outline_mask_path = outline_on and anim_pfx and anim_pfx ~= ""
  local tr, tg, tb = rgb_eel_parts(st.text_color or 0xFFFFFF)
  local hr, hg, hb = rgb_eel_parts(st.highlight_color or 0xFFD34D)
  local othick = math.max(1, math.min(12, math.floor(tonumber(st.outline_thickness) or 2)))
  local ogap = math.max(0, math.min(24, math.floor(tonumber(st.outline_gap) or 0)))
  local or_, og, ob = rgb_eel_parts(tonumber(st.outline_color) or 0)
  local ps_extra = (outline_mask_path and (8 + 2 * (ogap + othick))) or 0
  local shadow_dx = fmt_eel_num(st.shadow_dx or 2)
  local shadow_dy = fmt_eel_num(st.shadow_dy or 2)
  local shadow_alpha = fmt_eel_num(st.shadow_alpha or 0.55)
  local underline_thick = fmt_eel_num(st.underline_thick or 1)
  local underline_offset = fmt_eel_num(st.underline_offset or 1)
  local pseudo_slant = tonumber(st.pseudo_slant) or 2
  local pseudo_slant_dx = "(" .. h_expr .. "*" .. fmt_eel_num(pseudo_slant / 45) .. ")"
  local pseudo_bold_copies = math.max(1, math.min(8, math.floor(tonumber(st.pseudo_bold_copies) or 2)))
  local pseudo_bold_offset = tonumber(st.pseudo_bold_offset) or 1

  local fr = {}
  local function add(s)
    fr[#fr + 1] = s
  end
  if anim_pfx and anim_pfx ~= "" and not outline_mask_path then
    local blur = anim_pfx .. "b"
    add(string.format(
      "(%s > 0.001) ? (gfx_set(%s,%s,%s,0.11*%s); gfx_str_draw(%s,%s-%s,%s); gfx_str_draw(%s,%s+%s,%s); gfx_str_draw(%s,%s,%s-%s); gfx_str_draw(%s,%s,%s+%s); gfx_str_draw(%s,%s-%s*0.707,%s-%s*0.707); gfx_str_draw(%s,%s+%s*0.707,%s-%s*0.707); gfx_str_draw(%s,%s-%s*0.707,%s+%s*0.707); gfx_str_draw(%s,%s+%s*0.707,%s+%s*0.707));",
      blur,
      tr,
      tg,
      tb,
      alpha_expr,
      text_expr,
      x_expr,
      blur,
      y_expr,
      text_expr,
      x_expr,
      blur,
      y_expr,
      text_expr,
      x_expr,
      y_expr,
      blur,
      text_expr,
      x_expr,
      y_expr,
      blur,
      text_expr,
      x_expr,
      blur,
      y_expr,
      blur,
      text_expr,
      x_expr,
      blur,
      y_expr,
      blur,
      text_expr,
      x_expr,
      blur,
      y_expr,
      blur,
      text_expr,
      x_expr,
      blur,
      y_expr,
      blur
    ))
    for i = 1, ANIM_MAX_DUPES do
      local ga = anim_pfx .. "g" .. tostring(i) .. "a"
      local gx = anim_pfx .. "g" .. tostring(i) .. "x"
      local gy = anim_pfx .. "g" .. tostring(i) .. "y"
      add(string.format(
        "(%s > 0.001) ? (gfx_set(%s,%s,%s,%s*%s); gfx_str_draw(%s,%s+%s,%s+%s));",
        ga,
        tr,
        tg,
        tb,
        alpha_expr,
        ga,
        text_expr,
        x_expr,
        gx,
        y_expr,
        gy
      ))
    end
  end
  if (flags & WSTYLE_HIGHLIGHT) ~= 0 and not outline_mask_path then
    add(string.format(
      "gfx_set(%s,%s,%s,0.38*%s); gfx_fillrect(%s-3,%s-2,%s+6,%s+4);",
      hr,
      hg,
      hb,
      alpha_expr,
      x_expr,
      y_expr,
      w_expr,
      h_expr
    ))
  end
  if (flags & WSTYLE_SHADOW) ~= 0 and not outline_mask_path then
    add(string.format(
      "gfx_set(0,0,0,%s*%s); gfx_str_draw(%s,%s+%s,%s+%s);",
      shadow_alpha,
      alpha_expr,
      text_expr,
      x_expr,
      shadow_dx,
      y_expr,
      shadow_dy
    ))
  end
  if (flags & WSTYLE_PSEUDO_SLANT) ~= 0 then
    add(string.format(
      "gfx_set(%s,%s,%s,0.45*%s); gfx_str_draw(%s,%s+%s,%s-1);",
      tr,
      tg,
      tb,
      alpha_expr,
      text_expr,
      x_expr,
      pseudo_slant_dx,
      y_expr
    ))
  end
  if outline_on and not outline_mask_path then
    if othick <= 1 and ogap == 0 then
      add(string.format(
        "gfx_set(%s,%s,%s,0.72*%s); gfx_str_draw(%s,(%s)-1,%s); gfx_str_draw(%s,(%s)+1,%s); gfx_str_draw(%s,%s,(%s)-1); gfx_str_draw(%s,%s,(%s)+1);",
        or_,
        og,
        ob,
        alpha_expr,
        text_expr,
        x_expr,
        y_expr,
        text_expr,
        x_expr,
        y_expr,
        text_expr,
        x_expr,
        y_expr,
        text_expr,
        x_expr,
        y_expr
      ))
    else
      append_word_outline_halo_eel(add, text_expr, x_expr, y_expr, alpha_expr, or_, og, ob, ogap, othick)
    end
  end
  add(string.format("gfx_set(%s,%s,%s,%s); gfx_str_draw(%s,%s,%s);", tr, tg, tb, alpha_expr, text_expr, x_expr, y_expr))
  if (flags & WSTYLE_PSEUDO_BOLD) ~= 0 then
    for i = 1, pseudo_bold_copies do
      local dx = fmt_eel_num(pseudo_bold_offset * i)
      add(string.format("gfx_str_draw(%s,%s+%s,%s);", text_expr, x_expr, dx, y_expr))
    end
  end
  if (flags & WSTYLE_UNDERLINE) ~= 0 then
    add(string.format("gfx_fillrect(%s,%s+%s+%s,%s,%s);", x_expr, y_expr, h_expr, underline_offset, w_expr, underline_thick))
  end

  local function flush_fr(prefix)
    for i = 1, #fr do
      lines[#lines + 1] = prefix .. fr[i]
    end
  end

  local function append_occluder(prefix)
    if not anim_pfx or anim_pfx == "" then
      return
    end
    local mk = anim_pfx .. "mk"
    local mm = anim_pfx .. "m"
    local mx = anim_pfx .. "mx"
    local my = anim_pfx .. "my"
    local mo = anim_pfx .. "mo"
    lines[#lines + 1] = prefix .. string.format("((%s > 0.5) ? (", mk)
    lines[#lines + 1] = prefix .. string.format(
      "  wxov_m=max(0,min(1,%s)); wxov_w=max(0,floor(%s+0.5)); wxov_hh=max(0,floor(%s+0.5)); wxov_x=%s; wxov_y=%s; wxov_ax=abs(%s); wxov_ay=abs(%s);",
      mm,
      w_expr,
      h_expr,
      x_expr,
      y_expr,
      mx,
      my
    )
    lines[#lines + 1] = prefix .. "  (wxov_ax>=wxov_ay) ? ("
    lines[#lines + 1] = prefix .. string.format(
      "    wxov_cw=max(0,min(wxov_w,floor(wxov_w*wxov_m+0.5))); (%s>=0) ? (wxov_hx=wxov_x+wxov_cw; wxov_hw=max(0,wxov_w-wxov_cw);) : (wxov_hx=wxov_x; wxov_hw=max(0,wxov_w-wxov_cw)); wxov_hy=wxov_y; wxov_hh2=wxov_hh;",
      mx
    )
    lines[#lines + 1] = prefix .. "  ) : ("
    lines[#lines + 1] = prefix .. string.format(
      "    wxov_ch=max(0,min(wxov_hh,floor(wxov_hh*wxov_m+0.5))); (%s>=0) ? (wxov_hy=wxov_y+wxov_ch; wxov_hh2=max(0,wxov_hh-wxov_ch);) : (wxov_hy=wxov_y; wxov_hh2=max(0,wxov_hh-wxov_ch)); wxov_hx=wxov_x; wxov_hw=wxov_w;",
      my
    )
    lines[#lines + 1] = prefix .. "  );"
    lines[#lines + 1] = prefix .. "  ((wxov_hw>0) && (wxov_hh2>0)) ? (gfx_set(0,0,0,1); gfx_fillrect(wxov_hx,wxov_hy,wxov_hw,wxov_hh2);) : 0;"
    lines[#lines + 1] = prefix .. ") : 0);"
  end

  if anim_pfx and anim_pfx ~= "" then
    if not image_mask_fx and not outline_mask_path then
      flush_fr("  ")
      append_occluder("  ")
      return
    end
    local sx = anim_pfx .. "sx"
    local sy = anim_pfx .. "sy"
    local mk = anim_pfx .. "mk"
    local mm = anim_pfx .. "m"
    local mx = anim_pfx .. "mx"
    local my = anim_pfx .. "my"
    local mo = anim_pfx .. "mo"
    local needs_img_expr = string.format("max(max((%s>0.5?1:0),(abs(%s-1)>0.001?1:0)),(abs(%s-1)>0.001?1:0))", mk, sx, sy)
    if rot_var and rot_var ~= "" then
      needs_img_expr = "max(" .. needs_img_expr .. string.format(",(abs(%s)>0.001?1:0))", rot_var)
    end
    if outline_mask_path then
      needs_img_expr = "max(" .. needs_img_expr .. ",1)"
    end
    lines[#lines + 1] = "  wxov_useimg=" .. needs_img_expr .. "; (wxov_useimg>0.5) ? ("
    lines[#lines + 1] = string.format(
      "  od=gfx_dest; colorspace='RGBA'; wxov_ps=max(%s,%s)+%d; wxov_spin=max(0,floor(wxov_spin+0.5))<1 ? gfx_img_alloc(wxov_ps,wxov_ps,1) : gfx_img_resize(wxov_spin,wxov_ps,wxov_ps,1); gfx_dest=wxov_spin; gfx_set(0,1,0,1); gfx_fillrect(0,0,wxov_ps,wxov_ps); wxov_px=floor((wxov_ps-%s)*0.5); wxov_py=floor((wxov_ps-%s)*0.5);",
      w_expr,
      h_expr,
      96 + ps_extra,
      w_expr,
      h_expr
    )
    local fr2 = {}
    for i = 1, #fr do
      fr2[i] = replace_eel_expr_plain(replace_eel_expr_plain(fr[i], x_expr, "wxov_px"), y_expr, "wxov_py")
    end
    for i = 1, #fr2 do
      lines[#lines + 1] = "  " .. fr2[i]
    end
    lines[#lines + 1] = "  wxov_srcx=0; wxov_srcy=0; wxov_srcw=wxov_ps; wxov_srch=wxov_ps;"
    lines[#lines + 1] = string.format("  ((%s > 0.5) ? (", mk)
    lines[#lines + 1] = string.format(
      "    wxov_m=max(0,min(1,%s)); wxov_ax=abs(%s); wxov_ay=abs(%s); wxov_cut=floor(wxov_ps*wxov_m+%s+0.5);",
      mm,
      mx,
      my,
      mo
    )
    lines[#lines + 1] = "    (wxov_ax>=wxov_ay) ? ("
    lines[#lines + 1] = string.format(
      "      (%s>=0) ? (wxov_hx=max(0,min(wxov_ps,wxov_cut)); wxov_hw=max(0,wxov_ps-wxov_hx);) : (wxov_hx=0; wxov_hw=max(0,min(wxov_ps,wxov_ps-wxov_cut));); wxov_hy=0; wxov_hh2=wxov_ps;",
      mx
    )
    lines[#lines + 1] = "    ) : ("
    lines[#lines + 1] = string.format(
      "      (%s>=0) ? (wxov_hy=max(0,min(wxov_ps,wxov_cut)); wxov_hh2=max(0,wxov_ps-wxov_hy);) : (wxov_hy=0; wxov_hh2=max(0,min(wxov_ps,wxov_ps-wxov_cut));); wxov_hx=0; wxov_hw=wxov_ps;",
      my
    )
    lines[#lines + 1] = "    );"
    lines[#lines + 1] = "    ((wxov_hw>0) && (wxov_hh2>0)) ? (gfx_set(0,1,0,1); gfx_fillrect(wxov_hx,wxov_hy,wxov_hw,wxov_hh2);) : 0;"
    lines[#lines + 1] = "  ) : 0);"
    lines[#lines + 1] = '  gfx_evalrect(0,0,wxov_ps,wxov_ps,"_1=max(max(r,b),255-g); _1<8 ? (a=0;) : (a=min(255,_1); r=min(255,r*255/_1); g=min(255,max(0,g-(255-_1))*255/_1); b=min(255,b*255/_1););");'
    if outline_mask_path then
      append_outline_mask_post_eel(lines, or_, og, ob, tr, tg, tb, ogap, othick)
    end
    lines[#lines + 1] = string.format(
      "  wxov_sx=max(0.03,%s); wxov_sy=max(0.03,%s); wxov_dw=floor(wxov_ps*wxov_sx+0.5); wxov_dh=floor(wxov_ps*wxov_sy+0.5); wxov_dx=floor((%s)+(%s)*0.5-(wxov_px+(%s)*0.5)*wxov_sx+0.5); wxov_dy=floor((%s)+(%s)*0.5-(wxov_py+(%s)*0.5)*wxov_sy+0.5);",
      sx,
      sy,
      x_expr,
      w_expr,
      w_expr,
      y_expr,
      h_expr,
      h_expr
    )
    lines[#lines + 1] = "  gfx_dest=od; gfx_mode=0x10000;"
    if rot_var and rot_var ~= "" then
      lines[#lines + 1] = string.format(
        "  (abs(%s)<0.001) ? (gfx_blit(wxov_spin,0,wxov_dx,wxov_dy,wxov_dw,wxov_dh,0,0,wxov_ps,wxov_ps);) : (gfx_rotoblit(wxov_spin,%s,wxov_dx,wxov_dy,wxov_dw,wxov_dh,0,0,wxov_ps,wxov_ps,0x10000,floor(wxov_dw*0.5),floor(wxov_dh*0.5)););",
        rot_var, rot_var)
    else
      lines[#lines + 1] = "  gfx_blit(wxov_spin,0,wxov_dx,wxov_dy,wxov_dw,wxov_dh,0,0,wxov_ps,wxov_ps);"
    end
    lines[#lines + 1] = "  gfx_mode=0; gfx_a=1;"
    lines[#lines + 1] = "  ) : ("
    flush_fr("    ")
    append_occluder("    ")
    lines[#lines + 1] = "  );"
    return
  end

  if not rot_var or rot_var == "" then
    flush_fr("    ")
    return
  end

  lines[#lines + 1] = string.format("  (abs(%s)<0.001)?(", rot_var)
  flush_fr("    ")
  lines[#lines + 1] = "  ):("
  lines[#lines + 1] = string.format(
    "    od=gfx_dest; wxov_spin=max(0,floor(wxov_spin+0.5))<1 ? gfx_img_alloc(2048,768,1) : wxov_spin; gfx_dest=wxov_spin; wxov_ps=max(%s,%s)+48; gfx_set(0,0,0,0); gfx_fillrect(0,0,wxov_ps,wxov_ps); wxov_px=floor((wxov_ps-%s)*0.5); wxov_py=floor((wxov_ps-%s)*0.5);",
    w_expr,
    h_expr,
    w_expr,
    h_expr
  )
  local fr2 = {}
  for i = 1, #fr do
    fr2[i] = replace_eel_expr_plain(replace_eel_expr_plain(fr[i], x_expr, "wxov_px"), y_expr, "wxov_py")
  end
  for i = 1, #fr2 do
    lines[#lines + 1] = "    " .. fr2[i]
  end
  lines[#lines + 1] = string.format(
    "    gfx_dest=od; gfx_rotoblit(wxov_spin, %s, %s-wxov_px, %s-wxov_py, wxov_ps, wxov_ps, 0, 0, wxov_ps, wxov_ps, 0, floor(wxov_ps*0.5), floor(wxov_ps*0.5));",
    rot_var,
    x_expr,
    y_expr
  )
  lines[#lines + 1] = "  );"
end

--- True when overlay text should join wx| tokens with no spaces (JP/CN-style).
--- Uses Hiragana/Katakana/CJK ideographs vs Latin letters on all marker words.
local function words_use_cjk_compact_join(words)
  if not words or #words == 0 or not utf8 or not utf8.codes then
    return false
  end
  local cjk, latin = 0, 0
  for i = 1, #words do
    local w = words[i].w or ""
    pcall(function()
      for _, cp in utf8.codes(w) do
        if
          (cp >= 0x3040 and cp <= 0x309F)
          or (cp >= 0x30A0 and cp <= 0x30FF)
          or (cp >= 0x3400 and cp <= 0x4DBF)
          or (cp >= 0x4E00 and cp <= 0x9FFF)
          or (cp >= 0xFF66 and cp <= 0xFF9F)
        then
          cjk = cjk + 1
        elseif (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x61 and cp <= 0x7A) then
          latin = latin + 1
        elseif cp >= 0x00C0 and cp <= 0x024F then
          latin = latin + 1
        end
      end
    end)
  end
  if cjk == 0 then
    return false
  end
  if latin == 0 then
    return true
  end
  return cjk > latin
end

--- between_len: UTF-8 bytes inserted between words when counting line width (0 = CJK, 1 = space).
local function line_char_count(words_in_line, between_len)
  between_len = (between_len ~= nil) and between_len or 1
  local n = 0
  for j = 1, #words_in_line do
    n = n + #words_in_line[j].w + (j > 1 and between_len or 0)
  end
  return n
end

--- @param words_per_line integer >= 1
--- @param max_chars 0 = unlimited line width
local function split_words_into_lines(words, words_per_line, max_chars, break_after_sentence)
  words_per_line = math.max(1, math.floor(tonumber(words_per_line) or 8))
  max_chars = math.max(0, math.floor(tonumber(max_chars) or 0))
  local gap = words_use_cjk_compact_join(words) and 0 or 1
  local lines = {}
  local cur = {}
  for i = 1, #words do
    local w = words[i]
    if #cur >= 1 then
      local too_many = #cur >= words_per_line
      local too_long = max_chars > 0
        and (line_char_count(cur, gap) + (#cur >= 1 and gap or 0) + #w.w > max_chars)
      if too_many or too_long then
        lines[#lines + 1] = cur
        cur = {}
      end
    end
    cur[#cur + 1] = w
    if break_after_sentence and w.w:match("[%.%!%?…]$") then
      lines[#lines + 1] = cur
      cur = {}
    end
  end
  if #cur > 0 then
    lines[#lines + 1] = cur
  end
  return lines
end

local function join_words_range(line_words, from_i, to_i, join_sep)
  join_sep = join_sep ~= nil and join_sep or " "
  local t = {}
  for j = from_i, to_i do
    t[#t + 1] = line_words[j].w
  end
  return table.concat(t, join_sep)
end

local function global_index_after_word(words, w)
  for j = 1, #words do
    if words[j].w == w.w and math.abs(words[j].t - w.t) < 1e-9 then
      return j
    end
  end
  return nil
end

local function segment_t1_after_word(words, w, src_end)
  local j = global_index_after_word(words, w)
  if j and j < #words then
    return words[j + 1].t
  end
  return src_end or (w.t + 2.0)
end

local function time_after_word_index(words, idx, src_end)
  if idx < #words then
    return words[idx + 1].t
  end
  return src_end or (words[idx].t + 2.0)
end

local function whitespace_tokens(line)
  local t = {}
  for w in line:gmatch("%S+") do
    t[#t + 1] = w
  end
  return t
end

--- Remove grave accents for overlay editor ↔ marker comparisons (editor text is normalized too).
local function strip_overlay_grave(s)
  if type(s) ~= "string" then
    return ""
  end
  return s:gsub("`", "")
end

--- CRLF → LF; strip grave accents; peel broken UTF-8 tails per phrase line (helps stale P_EXT / extstate).
local function normalize_editor_text_for_overlay(editor_text)
  if type(editor_text) ~= "string" then
    return ""
  end
  local et = strip_overlay_grave(editor_text:gsub("\r\n", "\n"):gsub("\r", "\n"))
  if et == "" then
    return ""
  end
  local lines_out = {}
  local pos = 1
  while true do
    local i = et:find("\n", pos)
    local ln = i and et:sub(pos, i - 1) or et:sub(pos)
    lines_out[#lines_out + 1] = utf8_trim_invalid_suffix(ln)
    if not i then
      break
    end
    pos = i + 1
  end
  return table.concat(lines_out, "\n")
end

local function split_editor_lines(editor_text)
  local lines = {}
  local pos = 1
  while true do
    local i, j = editor_text:find("\n", pos)
    if not i then
      lines[#lines + 1] = editor_text:sub(pos)
      break
    end
    lines[#lines + 1] = editor_text:sub(pos, i - 1)
    pos = j + 1
  end
  return lines
end

--- First 1-based byte index where a and b differ; if one is a prefix of the other, returns len(shorter)+1.
local function first_mismatch_byte_between(a, b)
  local lim = math.min(#a, #b)
  for i = 1, lim do
    if a:sub(i, i) ~= b:sub(i, i) then
      return i
    end
  end
  if #a ~= #b then
    return lim + 1
  end
  return nil
end

--- Byte offset in `line` of the first character of the n-th whitespace-separated token (1-based n).
local function byte_pos_of_nth_token_start(line, n)
  if n < 1 or type(line) ~= "string" then
    return 1
  end
  local idx = 0
  local p = 1
  while p <= #line do
    local ws_b, ws_e = line:find("^%s+", p)
    if ws_b then
      p = ws_e + 1
    end
    if p > #line then
      return #line + 1
    end
    local tok_b, tok_e = line:find("%S+", p)
    if not tok_b then
      return #line + 1
    end
    idx = idx + 1
    if idx == n then
      return tok_b
    end
    p = tok_e + 1
  end
  return #line + 1
end

--- JP/CN: each non-empty line must equal marker word texts concatenated left-to-right (no spaces between words).
local function parse_editor_line_groups_cjk(words, editor_text)
  local groups = {}
  local wi = 1
  for li, raw in ipairs(split_editor_lines(editor_text)) do
      local line = raw:match("^%s*(.-)%s*$") or raw
      local lcmp = strip_overlay_grave(line)
      if line ~= "" then
        if wi > #words then
        return nil,
          "Editor line " .. li .. ": extra text after all marker words were used.",
          {
            mode = "cjk_extra",
            line_num = li,
            good_prefix = "",
            bad_suffix = line,
            marker_concat = "",
            note = "This line is past the last marker word.",
          }
      end
      local start_w = wi
      local acc = ""
      local matched = false
      while wi <= #words do
        acc = acc .. words[wi].w
        local acmp = strip_overlay_grave(acc)
        if acmp == lcmp then
          groups[#groups + 1] = { start_w = start_w, end_w = wi, display = line }
          wi = wi + 1
          matched = true
          break
        end
        if #acmp < #lcmp and lcmp:sub(1, #acmp) == acmp then
          wi = wi + 1
        else
          local lim = math.min(#acmp, #lcmp)
          local mb = first_mismatch_byte_between(acmp:sub(1, lim), lcmp:sub(1, lim))
          if not mb then
            mb = lim + 1
          end
          local good = mb > 1 and line:sub(1, mb - 1) or ""
          local bad = mb <= #line and line:sub(mb) or ""
          return nil,
            "Editor line "
              .. li
              .. ": text does not match marker words (CJK: each line is marker words concatenated, no spaces between them).",
            {
              mode = "cjk_mismatch",
              line_num = li,
              good_prefix = good,
              bad_suffix = bad,
              marker_concat = acc,
              note = "Green = matches markers so far; red = first divergent part. Concat of markers tried: see marker_concat.",
            }
        end
      end
      if not matched then
        return nil,
          "Editor line " .. li .. ": not enough marker words left to complete this line.",
          {
            mode = "cjk_incomplete",
            line_num = li,
            good_prefix = line,
            bad_suffix = "",
            marker_concat = acc,
            note = "Marker text built from remaining words is shorter than this line (marker_concat vs line).",
          }
      end
    end
  end
  if wi ~= #words + 1 then
    return nil,
      string.format(
        "Not all marker words are placed in the editor (%d of %d). Add lines or merge text.",
        wi - 1,
        #words
      ),
      {
        mode = "cjk_tail",
        line_num = nil,
        good_prefix = "",
        bad_suffix = "",
        marker_concat = "",
        note = string.format("Used %d of %d marker words in the editor.", wi - 1, #words),
      }
  end
  return groups, nil, nil
end

--- Non-empty editor lines each map to a subtitle row. Latin: whitespace-separated tokens per line must match
--- take-marker words in order. JP/CN (compact): each line is the concatenation of one or more marker words with no spaces.
--- Empty lines are skipped.
local function parse_editor_line_groups(words, editor_text)
  if not words or #words == 0 then
    return nil, "No take marker words.", nil
  end
  editor_text = normalize_editor_text_for_overlay(editor_text)
  if words_use_cjk_compact_join(words) then
    return parse_editor_line_groups_cjk(words, editor_text)
  end
  local lines = split_editor_lines(editor_text)
  local groups = {}
  local wi = 1
  for li, line in ipairs(lines) do
    local toks = whitespace_tokens(line)
    if #toks > 0 then
      if wi + #toks - 1 > #words then
        local max_t = #words - wi + 1
        local bad_from = byte_pos_of_nth_token_start(line, max_t + 1)
        local good = bad_from > 1 and line:sub(1, bad_from - 1) or ""
        local bad = (bad_from <= #line) and line:sub(bad_from) or ""
        if good == "" and bad == "" then
          bad = line
        end
        return nil,
          "Editor line " .. li .. ": too many tokens for remaining marker words (" .. #words .. " total).",
          {
            mode = "latin_overflow",
            line_num = li,
            good_prefix = good,
            bad_suffix = bad,
            marker_concat = "",
            note = string.format("Only %d more marker word(s) left starting at editor token %d.", max_t, max_t + 1),
          }
      end
      groups[#groups + 1] = {
        start_w = wi,
        end_w = wi + #toks - 1,
        display = line,
      }
      wi = wi + #toks
    end
  end
  if wi - 1 ~= #words then
    return nil,
      string.format(
        "Token mismatch: %d marker word(s) but %d token(s) in the editor (add/remove words or fix line breaks).",
        #words,
        wi - 1
      ),
      {
        mode = "latin_count",
        line_num = nil,
        good_prefix = "",
        bad_suffix = "",
        marker_concat = "",
        note = string.format("Editor consumed %d token(s); need exactly %d.", wi - 1, #words),
      }
  end
  return groups, nil, nil
end

local function trim_display_line(s)
  if type(s) ~= "string" then
    return ""
  end
  return s:match("^%s*(.-)%s*$") or s
end

local function split_phrase_on_pipe(phrase_raw)
  local rows = {}
  local pos = 1
  while pos <= #phrase_raw do
    local j = phrase_raw:find("|", pos, true)
    if not j then
      rows[#rows + 1] = trim_display_line(phrase_raw:sub(pos))
      break
    end
    rows[#rows + 1] = trim_display_line(phrase_raw:sub(pos, j - 1))
    pos = j + 1
  end
  return rows
end

local function filter_nonempty_rows(rows)
  local out = {}
  for _, r in ipairs(rows) do
    if r ~= "" then
      out[#out + 1] = r
    end
  end
  return out
end

local function merge_rows_to_max(rows, max_rows, merge_sep)
  max_rows = math.max(1, math.floor(tonumber(max_rows) or 4))
  merge_sep = merge_sep or " "
  while #rows > max_rows do
    rows[max_rows] = rows[max_rows] .. merge_sep .. rows[max_rows + 1]
    table.remove(rows, max_rows + 1)
  end
  return rows
end

--- Display length: UTF-8 codepoints when available, else byte length.
local function display_utf8_len(s)
  if type(s) ~= "string" then
    return 0
  end
  if utf8 and utf8.len then
    local ok, n = pcall(utf8.len, s)
    if ok and type(n) == "number" then
      return n
    end
  end
  return #s
end

local function phrase_char_jitter_unit(seed, phrase_idx)
  seed = tonumber(seed) or 0
  phrase_idx = math.max(1, math.floor(tonumber(phrase_idx) or 1))
  local x = math.sin(seed * 0.00017 + phrase_idx * 12.9898) * 43758.5453
  x = x - math.floor(x)
  return x * 2 - 1
end

--- 0 = off; else max chars allowed per visual row for this phrase (±rand from display_opts).
local function phrase_row_char_limit(display_opts, phrase_idx)
  local base = math.floor(tonumber(display_opts and display_opts.layout_ml_row_chars) or 0)
  if base <= 0 then
    return 0
  end
  local span = math.max(0, math.floor(tonumber(display_opts.layout_ml_row_chars_rand) or 0))
  local seed = tonumber(display_opts.layout_ml_chars_seed) or 0
  local u = phrase_char_jitter_unit(seed, phrase_idx)
  return math.max(1, math.floor(base + u * span + 0.5))
end

local function shallow_copy_rows(rows)
  local t = {}
  for i, v in ipairs(rows or {}) do
    t[i] = v
  end
  return t
end

--- How many consecutive marker words starting at `wi` concatenate to `rowtext` (no spaces), or nil.
local function count_marker_words_matching_concat(rowtext, words, wi)
  if type(rowtext) ~= "string" or rowtext == "" then
    return nil
  end
  local j = wi
  local acc = ""
  local rcmp = strip_overlay_grave(rowtext)
  while j <= #words do
    acc = acc .. words[j].w
    local acmp = strip_overlay_grave(acc)
    if acmp == rcmp then
      return j - wi + 1
    end
    if #acmp < #rcmp and rcmp:sub(1, #acmp) == acmp then
      j = j + 1
    else
      return nil
    end
  end
  return nil
end

--- Latin: one `|` row → number of marker words it consumes, or nil + err.
local function latin_row_marker_count(rowtext, words, wi)
  local tks = whitespace_tokens(rowtext)
  if #tks < 1 then
    return nil, "empty row (cannot apply character limit)"
  end
  if #tks == 1 then
    local n = count_marker_words_matching_concat(tks[1], words, wi)
    if n then
      return n
    end
    if words[wi] and strip_overlay_grave(words[wi].w) == strip_overlay_grave(tks[1]) then
      return 1
    end
    return nil, "row text does not match marker words as typed (add spaces between words, or match exact run-on spellings)."
  end
  for ti, tok in ipairs(tks) do
    if wi + ti - 1 > #words or strip_overlay_grave(words[wi + ti - 1].w) ~= strip_overlay_grave(tok) then
      return nil, "token " .. ti .. " does not match marker word."
    end
  end
  return #tks
end

--- Pack `count` marker words starting at `start_i` into display rows ≤ `lim` (UTF-8 length); join with `sep` on a row.
local function pack_marker_words_into_char_rows(words, start_i, count, lim, sep)
  if count < 1 then
    return {}, nil
  end
  sep = sep or " "
  local rows = {}
  local cur = {}
  local function row_len_display(parts)
    if #parts == 0 then
      return 0
    end
    return display_utf8_len(table.concat(parts, sep))
  end
  for off = 0, count - 1 do
    local w = words[start_i + off].w
    if display_utf8_len(w) > lim then
      return nil, "a marker word exceeds the per-row character limit"
    end
    local trial = {}
    for _, x in ipairs(cur) do
      trial[#trial + 1] = x
    end
    trial[#trial + 1] = w
    if #cur > 0 and row_len_display(trial) > lim then
      rows[#rows + 1] = table.concat(cur, sep)
      cur = { w }
    else
      cur[#cur + 1] = w
    end
  end
  if #cur > 0 then
    rows[#rows + 1] = table.concat(cur, sep)
  end
  return rows, nil
end

--- Latin: split each pipe-row into more display rows under `lim`, using marker order (handles run-on without spaces).
local function expand_latin_cleaned_for_lim(cleaned, words, wi0, lim)
  local wi = wi0
  local out = {}
  for _, r in ipairs(cleaned) do
    local n, err = latin_row_marker_count(r, words, wi)
    if not n then
      return nil, err
    end
    local packed, perr = pack_marker_words_into_char_rows(words, wi, n, lim, " ")
    if not packed then
      return nil, perr
    end
    for _, sr in ipairs(packed) do
      out[#out + 1] = sr
    end
    wi = wi + n
  end
  return out, nil
end

local function concat_words_range(words, lo, hi)
  if not words or hi < lo then
    return ""
  end
  local parts = {}
  for i = lo, hi do
    parts[#parts + 1] = words[i] and words[i].w or ""
  end
  return table.concat(parts)
end

--- For each pipe-row string in `cleaned`, find inclusive word indices [lo,hi] matching marker concatenation.
--- Returns { ok=true, next_wi=W, spans=list } where spans[k]={lo,hi} aligns with cleaned[k]; or { ok=false, err=msg }.
local function cjk_match_cleaned_rows_word_spans(cleaned, words, wi0)
  local wi = wi0
  local spans = {}
  for ri, rowtext in ipairs(cleaned) do
    local j = wi
    local acc = ""
    local rtc = strip_overlay_grave(rowtext)
    while j <= #words do
      acc = acc .. words[j].w
      local accc = strip_overlay_grave(acc)
      if accc == rtc then
        break
      end
      if #accc < #rtc and rtc:sub(1, #accc) == accc then
        j = j + 1
      else
        return { ok = false, err = "row " .. ri .. " does not match marker word run" }
      end
    end
    if strip_overlay_grave(acc) ~= rtc then
      return { ok = false, err = "row " .. ri .. " is incomplete for marker words" }
    end
    local lo, hi = wi, j
    spans[#spans + 1] = { lo = lo, hi = hi }
    wi = j + 1
  end
  return { ok = true, next_wi = wi, spans = spans }
end

--- CJK: each `cleaned` row must match concat of consecutive marker words; split into shorter rows by `lim`.
local function expand_cjk_cleaned_for_lim(cleaned, words, wi0, lim)
  local mr = cjk_match_cleaned_rows_word_spans(cleaned, words, wi0)
  if not mr.ok then
    return nil, mr.err
  end
  local out = {}
  for ri = 1, #cleaned do
    local span = mr.spans[ri]
    local lo, hi = span.lo, span.hi
    local cur = ""
    for k = lo, hi do
      local w = words[k].w
      if display_utf8_len(w) > lim then
        return nil, "a marker word exceeds the per-row character limit"
      end
      local cand = cur .. w
      if cur == "" then
        cur = w
      elseif display_utf8_len(cand) > lim then
        out[#out + 1] = cur
        cur = w
      else
        cur = cand
      end
    end
    if cur ~= "" then
      out[#out + 1] = cur
    end
  end
  return out, nil
end

--- Reduce row count only by merging adjacent rows whose combined display length <= `lim`.
local function merge_rows_max_with_lim(rows, max_rows, sep, lim)
  max_rows = math.max(1, math.floor(tonumber(max_rows) or 4))
  rows = shallow_copy_rows(rows)
  sep = sep or " "
  while #rows > max_rows do
    local merged_pair = false
    for i = 1, #rows - 1 do
      local a, b = rows[i], rows[i + 1]
      local comb = (sep == "") and (a .. b) or (a .. sep .. b)
      if display_utf8_len(comb) <= lim then
        rows[i] = comb
        table.remove(rows, i + 1)
        merged_pair = true
        break
      end
    end
    if not merged_pair then
      return nil
    end
  end
  return rows
end

--- After `|` split (`cleaned`), optionally subdivide rows by char limit, then merge down to `max_rows`.
local function apply_multiline_char_limit_then_merge(cleaned, words, wi_start, cjk, max_rows, merge_sep, display_opts, phrase_idx)
  local lim = phrase_row_char_limit(display_opts, phrase_idx)
  local working = shallow_copy_rows(cleaned)
  if lim > 0 then
    if cjk then
      local exp, err = expand_cjk_cleaned_for_lim(working, words, wi_start, lim)
      if not exp then
        return nil, err
      end
      working = exp
    else
      local exp, err = expand_latin_cleaned_for_lim(working, words, wi_start, lim)
      if not exp then
        return nil, err
      end
      working = exp
    end
  end
  if lim > 0 then
    local merged = merge_rows_max_with_lim(working, max_rows, merge_sep, lim)
    if not merged then
      return nil,
        "cannot reduce to max rows without exceeding the per-row character limit (raise limit or max rows, or shorten the phrase)"
    end
    return merged, nil
  end
  return merge_rows_to_max(working, max_rows, merge_sep), nil
end

--- One phrase slice for multiline VP: logical `|` rows as strings (= concat(marker words)), exact word indices.
--- Built only from markers + phrase/row flags (no editor newline/`|` string parsing).
local function ml_phrase_specs_from_flags(words, phrase_after, row_after)
  local specs = {}
  if not words or #words == 0 then
    return specs
  end
  local n = #words
  local cjk = words_use_cjk_compact_join(words)
  local sep = cjk and "" or " "
  phrase_after = phrase_after or {}
  row_after = row_after or {}

  local phrase_w0 = 1
  local rows_cleaned = {}
  local line_buf = {}
  for i = 1, n do
    line_buf[#line_buf + 1] = words[i].w
    local pa = (i < n and phrase_after[i]) or (i == n)
    local ra = pa or ((i < n) and row_after[i]) or (i == n)
    if ra then
      rows_cleaned[#rows_cleaned + 1] = table.concat(line_buf, sep)
      line_buf = {}
    end
    if pa then
      local cleaned_copy = {}
      for r = 1, #rows_cleaned do
        cleaned_copy[r] = rows_cleaned[r]
      end
      specs[#specs + 1] = {
        wi_start = phrase_w0,
        wi_end = i,
        cleaned = cleaned_copy,
      }
      rows_cleaned = {}
      phrase_w0 = i + 1
    end
  end
  return specs
end

--- Triple-stack editor buffer from marker order only. `phrase_after[i]` / `row_after[i]` are for i = 1 .. n-1
--- (after word i: start new phrase / new row). Phrase break implies row break.
local function editor_text_from_ml_after_flags(words, phrase_after, row_after)
  if not words or #words == 0 then
    return ""
  end
  local n = #words
  local cjk = words_use_cjk_compact_join(words)
  local sep = cjk and "" or " "
  phrase_after = phrase_after or {}
  row_after = row_after or {}
  local phrases_out = {}
  local rows_buf = {}
  local line_buf = {}
  for i = 1, n do
    line_buf[#line_buf + 1] = words[i].w
    local pa = (i < n and phrase_after[i]) or (i == n)
    local ra = pa or ((i < n) and row_after[i]) or (i == n)
    if ra then
      rows_buf[#rows_buf + 1] = table.concat(line_buf, sep)
      line_buf = {}
    end
    if pa then
      phrases_out[#phrases_out + 1] = table.concat(rows_buf, " | ")
      rows_buf = {}
    end
  end
  return table.concat(phrases_out, "\n")
end

--- Triple/stairs: newline = phrase boundary; `|` splits visual rows inside one phrase. Grave `` ` `` in the field is stripped (ignored) before parse.
--- When `display_opts.ml_phrase_after` + `ml_row_after` are set (bridge triple CJK), phrase/row text is taken only from markers + flags — editor string is not parsed.
local function parse_editor_phrases_for_multiline(words, editor_text, display_opts)
  display_opts = display_opts or {}
  local max_rows = math.max(1, math.min(6, math.floor(tonumber(display_opts.layout_max_rows) or 4)))
  local cjk = words_use_cjk_compact_join(words)
  local preset = display_opts.preset or PRESET_WORD
  if
    (preset == PRESET_LINE_TRIPLE or preset == PRESET_LINE_STAIRS)
    and cjk
    and type(display_opts.ml_phrase_after) == "table"
    and type(display_opts.ml_row_after) == "table"
  then
    local pspecs = ml_phrase_specs_from_flags(words, display_opts.ml_phrase_after, display_opts.ml_row_after)
    if #words > 0 and #pspecs < 1 then
      return nil,
        "No phrases from phrase/row layout flags.",
        { mode = "ml_flags_empty", line_num = nil, good_prefix = "", bad_suffix = "", marker_concat = "", note = "" }
    end
    local phrases_flag = {}
    local wi_flag = 1
    for phrase_idx, pspec in ipairs(pspecs) do
      if pspec.wi_start ~= wi_flag then
        return nil,
          "Internal multiline layout: word cursor out of sync with phrase/row flags.",
          {
            mode = "ml_flags_sync",
            line_num = phrase_idx,
            good_prefix = "",
            bad_suffix = "",
            marker_concat = "",
            note = string.format("expected wi %d got phrase start %d", wi_flag, pspec.wi_start),
          }
      end
      local cleaned_flag = pspec.cleaned
      local merged_flag, mlim_err_flag = apply_multiline_char_limit_then_merge(
        cleaned_flag,
        words,
        wi_flag,
        cjk,
        max_rows,
        cjk and "" or " ",
        display_opts,
        phrase_idx
      )
      if not merged_flag then
        return nil,
          "Phrase " .. phrase_idx .. ": " .. tostring(mlim_err_flag or "character limit / row merge failed."),
          {
            mode = "ml_char_lim",
            line_num = phrase_idx,
            good_prefix = "",
            bad_suffix = "",
            marker_concat = "",
            note = "",
          }
      end
      local start_w = wi_flag
      local end_w = pspec.wi_end
      wi_flag = end_w + 1
      local row_end_w = {}
      local j = start_w
      for ri, rowtext in ipairs(merged_flag) do
        local acc2 = ""
        local rtc = strip_overlay_grave(rowtext)
        while j <= end_w do
          acc2 = acc2 .. words[j].w
          local a2c = strip_overlay_grave(acc2)
          if a2c == rtc then
            row_end_w[ri] = j
            j = j + 1
            break
          end
          if #a2c < #rtc and rtc:sub(1, #a2c) == a2c then
            j = j + 1
          else
            return nil,
              "Phrase "
                .. phrase_idx
                .. " row "
                .. ri
                .. ": marker word boundaries do not line up with layout rows.",
              { mode = "ml_cjk_row", line_num = phrase_idx, good_prefix = rowtext, bad_suffix = "", marker_concat = acc2, note = "" }
          end
        end
      end
      if j ~= end_w + 1 then
        return nil,
          "Phrase " .. phrase_idx .. ": row split does not consume all words in the phrase.",
          { mode = "ml_cjk_row_tail", line_num = phrase_idx, good_prefix = "", bad_suffix = "", marker_concat = "", note = "" }
      end
      phrases_flag[#phrases_flag + 1] = {
        start_w = start_w,
        end_w = end_w,
        rows = merged_flag,
        row_end_w = row_end_w,
        phrase_idx = phrase_idx,
      }
    end
    if wi_flag ~= #words + 1 then
      return nil,
        string.format(
          "Not all marker words are covered by phrase/row flags (%d of %d).",
          wi_flag - 1,
          #words
        ),
        {
          mode = "ml_tail",
          line_num = nil,
          good_prefix = "",
          bad_suffix = "",
          marker_concat = "",
          note = string.format("Flags consumed %d of %d marker words.", wi_flag - 1, #words),
        }
    end
    return phrases_flag, nil, nil
  end

  local et = normalize_editor_text_for_overlay(editor_text)
  local phrases = {}
  local wi = 1
  local phrase_idx = 0
  for _, raw in ipairs(split_editor_lines(et)) do
    local phrase_raw = trim_display_line(raw)
    if phrase_raw ~= "" then
      phrase_idx = phrase_idx + 1
      local rows0 = split_phrase_on_pipe(phrase_raw)
      local cleaned = filter_nonempty_rows(rows0)
      if #cleaned < 1 then
        return nil,
          "Phrase " .. phrase_idx .. ": nothing to show after splitting on |.",
          { mode = "ml_empty_phrase", line_num = phrase_idx, good_prefix = "", bad_suffix = phrase_raw, marker_concat = "", note = "" }
      end
      local merged, mlim_err = apply_multiline_char_limit_then_merge(
        cleaned,
        words,
        wi,
        cjk,
        max_rows,
        cjk and "" or " ",
        display_opts,
        phrase_idx
      )
      if not merged then
        return nil,
          "Phrase " .. phrase_idx .. ": " .. tostring(mlim_err or "character limit / row merge failed."),
          {
            mode = "ml_char_lim",
            line_num = phrase_idx,
            good_prefix = "",
            bad_suffix = phrase_raw,
            marker_concat = "",
            note = "",
          }
      end
      local start_w = wi
      local end_w
      local row_end_w = {}
      if cjk then
        local mr = cjk_match_cleaned_rows_word_spans(cleaned, words, wi)
        if not mr.ok then
          return nil,
            "Phrase " .. phrase_idx .. ": " .. mr.err .. " (CJK).",
            {
              mode = "ml_cjk_row",
              line_num = phrase_idx,
              good_prefix = phrase_raw,
              bad_suffix = "",
              marker_concat = "",
              note = mr.err,
            }
        end
        local flat_markers = concat_words_range(words, wi, mr.next_wi - 1)
        local flat_ui = table.concat(merged, "")
        if strip_overlay_grave(flat_ui) ~= strip_overlay_grave(flat_markers) then
          local lim_p = phrase_row_char_limit(display_opts, phrase_idx)
          local nphrase = mr.next_wi - wi
          if lim_p > 0 and nphrase > 0 then
            local packed = pack_marker_words_into_char_rows(words, wi, nphrase, lim_p, "")
            if packed then
              local mr_fix = merge_rows_max_with_lim(packed, max_rows, "", lim_p)
              merged = mr_fix or merge_rows_to_max({ flat_markers }, max_rows, "")
            else
              merged = merge_rows_to_max({ flat_markers }, max_rows, "")
            end
          else
            merged = merge_rows_to_max({ flat_markers }, max_rows, "")
          end
        end
        end_w = mr.next_wi - 1
        wi = mr.next_wi
        local j = start_w
        for ri, rowtext in ipairs(merged) do
          local acc2 = ""
          local rtc = strip_overlay_grave(rowtext)
          while j <= end_w do
            acc2 = acc2 .. words[j].w
            local a2c = strip_overlay_grave(acc2)
            if a2c == rtc then
              row_end_w[ri] = j
              j = j + 1
              break
            end
            if #a2c < #rtc and rtc:sub(1, #a2c) == a2c then
              j = j + 1
            else
              return nil,
                "Phrase "
                  .. phrase_idx
                  .. " row "
                  .. ri
                  .. ": marker word boundaries do not line up with | rows (each row must be whole marker words concatenated).",
                { mode = "ml_cjk_row", line_num = phrase_idx, good_prefix = rowtext, bad_suffix = "", marker_concat = acc2, note = "" }
            end
          end
        end
        if j ~= end_w + 1 then
          return nil,
            "Phrase " .. phrase_idx .. ": row split does not consume all words in the phrase.",
            { mode = "ml_cjk_row_tail", line_num = phrase_idx, good_prefix = "", bad_suffix = "", marker_concat = "", note = "" }
        end
      else
        local flat_line = table.concat(merged, " ")
        local toks = whitespace_tokens(flat_line)
        if #toks == 0 then
          return nil, "Phrase " .. phrase_idx .. ": no tokens.", nil
        end
        if wi + #toks - 1 > #words then
          return nil,
            "Phrase " .. phrase_idx .. ": too many tokens for remaining markers.",
            {
              mode = "ml_latin_overflow",
              line_num = phrase_idx,
              good_prefix = "",
              bad_suffix = flat_line,
              marker_concat = "",
              note = string.format("Only %d marker word(s) left.", #words - wi + 1),
            }
        end
        for ti = 1, #toks do
          if strip_overlay_grave(words[wi + ti - 1].w) ~= strip_overlay_grave(toks[ti]) then
            return nil,
              "Phrase " .. phrase_idx .. ": token " .. ti .. " does not match marker word.",
              {
                mode = "ml_latin_tok",
                line_num = phrase_idx,
                good_prefix = flat_line:sub(1, 20),
                bad_suffix = "",
                marker_concat = toks[ti] .. " vs " .. tostring(words[wi + ti - 1].w),
                note = "",
              }
          end
        end
        end_w = wi + #toks - 1
        local idx = wi
        for ri, rowtext in ipairs(merged) do
          local rt = whitespace_tokens(rowtext)
          if #rt < 1 then
            return nil, "Phrase " .. phrase_idx .. " row " .. ri .. ": empty row.", nil
          end
          idx = idx + #rt
          row_end_w[ri] = idx - 1
        end
        wi = end_w + 1
      end
      phrases[#phrases + 1] = {
        start_w = start_w,
        end_w = end_w,
        rows = merged,
        row_end_w = row_end_w,
        phrase_idx = phrase_idx,
      }
    end
  end
  if wi ~= #words + 1 then
    return nil,
      string.format(
        "Not all marker words are in the editor (%d of %d). Add phrases (newline) or words.",
        wi - 1,
        #words
      ),
      {
        mode = "ml_tail",
        line_num = nil,
        good_prefix = "",
        bad_suffix = "",
        marker_concat = "",
        note = string.format("Consumed %d of %d marker words.", wi - 1, #words),
      }
  end
  return phrases, nil, nil
end

--- Global word indices [rs,re] for phrase row `row_idx` (1-based), from row_end_w table.
local function ml_row_word_abs_range(phrase, row_idx)
  local rew = phrase.row_end_w
  if not rew or not rew[row_idx] then
    return nil, nil
  end
  local re = rew[row_idx]
  local rs = phrase.start_w
  if row_idx > 1 then
    local prev = rew[row_idx - 1]
    if not prev then
      return nil, nil
    end
    rs = prev + 1
  end
  if rs > re then
    return nil, nil
  end
  return rs, re
end

--- EEL: assigns visible substring into named string `eel_slot` for time `src` (karaoke grow).
--- gfx_str_draw / gfx_str_measure require `string #name`, not a value from a string ternary.
local function ml_row_karaoke_vis_eel(words, phrase, row_idx, join_sep, fallback_row_text, eel_slot)
  eel_slot = eel_slot or "#wxov_ml1"
  local rs, re = ml_row_word_abs_range(phrase, row_idx)
  if not rs then
    return string.format('strcpy(%s,"%s")', eel_slot, escape_eel_dq_string(fallback_row_text or ""))
  end
  local m = re - rs + 1
  if m < 1 then
    return string.format('strcpy(%s,"%s")', eel_slot, escape_eel_dq_string(fallback_row_text or ""))
  end
  local prefixes = {}
  prefixes[0] = '""'
  for k = 1, m do
    local parts = {}
    for j = rs, rs + k - 1 do
      parts[#parts + 1] = (words[j] and words[j].w) or ""
    end
    prefixes[k] = '"' .. escape_eel_dq_string(table.concat(parts, join_sep)) .. '"'
  end
  local expr = string.format("strcpy(%s,%s)", eel_slot, prefixes[m])
  for j = m - 1, 1, -1 do
    expr = string.format("(src < %s) ? strcpy(%s,%s) : (%s)", fmt_eel_num(words[rs + j].t), eel_slot, prefixes[j], expr)
  end
  expr = string.format("(src < %s) ? strcpy(%s,%s) : (%s)", fmt_eel_num(words[rs].t), eel_slot, prefixes[0], expr)
  return expr
end

--- EEL: visible text = single current word only (no cumulative prefix), same timing grid as write-on.
local function ml_row_single_word_vis_eel(words, phrase, row_idx, join_sep, fallback_row_text, eel_slot)
  eel_slot = eel_slot or "#wxov_ml1"
  join_sep = join_sep or " "
  local rs, re = ml_row_word_abs_range(phrase, row_idx)
  if not rs then
    return string.format('strcpy(%s,"%s")', eel_slot, escape_eel_dq_string(fallback_row_text or ""))
  end
  local m = re - rs + 1
  if m < 1 then
    return string.format('strcpy(%s,"%s")', eel_slot, escape_eel_dq_string(fallback_row_text or ""))
  end
  local prefixes = {}
  prefixes[0] = '""'
  for k = 1, m do
    local lit = (words[rs + k - 1] and words[rs + k - 1].w) or ""
    prefixes[k] = '"' .. escape_eel_dq_string(lit) .. '"'
  end
  local expr = string.format("strcpy(%s,%s)", eel_slot, prefixes[m])
  for j = m - 1, 1, -1 do
    expr = string.format("(src < %s) ? strcpy(%s,%s) : (%s)", fmt_eel_num(words[rs + j].t), eel_slot, prefixes[j], expr)
  end
  expr = string.format("(src < %s) ? strcpy(%s,%s) : (%s)", fmt_eel_num(words[rs].t), eel_slot, prefixes[0], expr)
  return expr
end

local function layout_segment_from_phrase(phrase, words, src_end, preset, karaoke, display_opts)
  local rows = phrase.rows or {}
  local n = #rows
  if n < 1 then
    return nil
  end
  local scales = (display_opts and display_opts.layout_line_scales) or {}
  local rands = (display_opts and display_opts.layout_line_rand) or {}
  local jit = display_opts and display_opts.layout_rand_jitter
  local row_mul = {}
  for i = 1, n do
    local base = tonumber(scales[i]) or 1
    local rng = math.max(0, tonumber(rands[i]) or 0)
    local jt = 0
    if type(jit) == "table" then
      jt = tonumber(jit[i]) or 0
    else
      jt = math.random() * 2 - 1
    end
    local f = base * (1 + jt * rng)
    row_mul[i] = math.max(0.12, f)
  end
  local t0 = words[phrase.start_w].t
  local t1 = time_after_word_index(words, phrase.end_w, src_end)
  if t1 <= t0 then
    t1 = t0 + 0.05
  end
  local timing = tonumber(display_opts and display_opts.ml_timing_mode)
  if timing == nil then
    timing = karaoke and 0 or 1
  end
  timing = math.max(0, math.min(2, math.floor(timing)))
  local phrase_static = timing == 1
  local mode_write_on = timing == 0
  local mode_single_word = timing == 2

  local seg_karaoke_flag = not phrase_static

  local t_rev = {}
  if seg_karaoke_flag and phrase.row_end_w then
    for i = 1, n - 1 do
      local ew = phrase.row_end_w[i]
      if ew then
        t_rev[i] = time_after_word_index(words, ew, src_end)
      end
    end
  end
  local gapm = 0.1
  if display_opts and display_opts.layout_line_gap ~= nil then
    gapm = tonumber(display_opts.layout_line_gap) or gapm
  end
  gapm = math.max(-0.95, math.min(0.5, gapm))
  local step = 0
  local span = 0
  if display_opts then
    step = math.max(0, math.min(0.5, tonumber(display_opts.layout_indent_step) or 0))
    span = math.max(0, math.min(0.25, tonumber(display_opts.layout_indent_rand) or 0))
  end
  local seed = (display_opts and tonumber(display_opts.layout_indent_seed)) or 0
  local pidx = math.max(1, math.floor(tonumber(phrase.phrase_idx) or 1))
  local u = phrase_char_jitter_unit(seed, pidx + 901)
  local eff = math.max(0, math.min(0.5, step + u * span))
  local row_x_frac = {}
  for i = 1, n do
    row_x_frac[i] = (i - 1) * eff
  end
  local lws = display_opts and display_opts.layout_word_scale
  local word_per_gfx = type(lws) == "table"
  local row_karaoke_vis_eel = nil
  if not word_per_gfx then
    local join_sep = words_use_cjk_compact_join(words) and "" or " "
    if mode_write_on then
      row_karaoke_vis_eel = {}
      for ri = 1, n do
        row_karaoke_vis_eel[ri] = ml_row_karaoke_vis_eel(words, phrase, ri, join_sep, rows[ri], "#wxov_ml" .. ri)
      end
    elseif mode_single_word then
      row_karaoke_vis_eel = {}
      for ri = 1, n do
        row_karaoke_vis_eel[ri] = ml_row_single_word_vis_eel(words, phrase, ri, join_sep, rows[ri], "#wxov_ml" .. ri)
      end
    end
  end
  local rsw, rew = {}, {}
  if phrase.row_end_w then
    for ri = 1, n do
      rew[ri] = phrase.row_end_w[ri]
      rsw[ri] = (ri == 1) and phrase.start_w or (phrase.row_end_w[ri - 1] + 1)
    end
  end
  local row_indent = display_opts and display_opts.layout_row_indent
  if type(row_indent) == "table" then
    for ri = 1, n do
      local rs = rsw[ri]
      if rs then
        row_x_frac[ri] = math.max(-0.5, math.min(0.5, (row_x_frac[ri] or 0) + (tonumber(row_indent[rs]) or 0)))
      end
    end
  end
  local row_gap_mul = {}
  for ri = 2, n do
    row_gap_mul[ri] = gapm
  end
  local row_gap = display_opts and display_opts.layout_row_gap
  if type(row_gap) == "table" then
    for ri = 2, n do
      local rs = rsw[ri]
      if rs and row_gap[rs] ~= nil then
        row_gap_mul[ri] = math.max(-0.95, math.min(1.5, tonumber(row_gap[rs]) or gapm))
      end
    end
  end
  return {
    t0 = t0,
    t1 = t1,
    layout = "triple",
    rows = rows,
    row_mul = row_mul,
    line_gap_mul = gapm,
    row_gap_mul = row_gap_mul,
    row_v_align = math.max(0, math.min(2, math.floor(tonumber(display_opts and display_opts.layout_row_v_align) or 0))),
    row_x_frac = row_x_frac,
    karaoke = seg_karaoke_flag,
    t_rev_karaoke = t_rev,
    row_karaoke_vis_eel = row_karaoke_vis_eel,
    row_start_w = rsw,
    row_end_w = rew,
    word_per_gfx = word_per_gfx,
    phrase_start_w = phrase.start_w,
    phrase_end_w = phrase.end_w,
  }
end

local function segments_from_phrases_multiline(words, src_end, preset, phrases, display_opts)
  local segs = {}
  for pi = 1, #phrases do
    local seg = layout_segment_from_phrase(phrases[pi], words, src_end, preset, display_opts.karaoke, display_opts)
    if seg then
      segs[#segs + 1] = seg
    end
  end
  return segs
end

local function fake_editor_group_from_slider_line(words, ln, join_sep)
  if not ln or #ln < 1 then
    return nil
  end
  local j0, j1
  for j = 1, #words do
    if words[j] == ln[1] then
      j0 = j
    end
    if words[j] == ln[#ln] then
      j1 = j
    end
  end
  if not j0 or not j1 then
    return nil
  end
  return {
    start_w = j0,
    end_w = j1,
    display = join_words_range(ln, 1, #ln, join_sep),
  }
end

local function segments_from_editor_groups(words, src_end, preset, groups, display_opts)
  display_opts = display_opts or {}
  local karaoke = display_opts.karaoke and true or false
  local segs = {}
  if preset == PRESET_WORD then
    local flat = {}
    if words_use_cjk_compact_join(words) then
      for _, g in ipairs(groups) do
        for j = g.start_w, g.end_w do
          flat[#flat + 1] = words[j].w
        end
      end
    else
      for _, g in ipairs(groups) do
        for t in g.display:gmatch("%S+") do
          flat[#flat + 1] = t
        end
      end
    end
    for i = 1, #words do
      local t0 = words[i].t
      local t1 = time_after_word_index(words, i, src_end)
      if t1 <= t0 then
        t1 = t0 + 0.05
      end
      segs[#segs + 1] = { t0 = t0, t1 = t1, text = flat[i] or "" }
    end
    return segs
  end

  local line_full_static = (preset == PRESET_LINE_FULL and not karaoke) or (preset == PRESET_LINE_GROW and not karaoke)
  local line_grow_motion = (preset == PRESET_LINE_FULL and karaoke) or (preset == PRESET_LINE_GROW and karaoke)

  if line_full_static then
    for _, g in ipairs(groups) do
      local t0 = words[g.start_w].t
      local t1 = time_after_word_index(words, g.end_w, src_end)
      if t1 <= t0 then
        t1 = t0 + 0.05
      end
      local disp = g.display:match("^%s*(.-)%s*$") or g.display
      segs[#segs + 1] = { t0 = t0, t1 = t1, text = disp }
    end
    return segs
  end

  if line_grow_motion then
    if words_use_cjk_compact_join(words) then
      local sep = ""
      for _, g in ipairs(groups) do
        local line_t1 = time_after_word_index(words, g.end_w, src_end)
        local ln = {}
        for j = g.start_w, g.end_w do
          ln[#ln + 1] = words[j]
        end
        for k = 1, #ln do
          local wi = g.start_w + k - 1
          local t0 = words[wi].t
          local t1
          if wi < g.end_w then
            t1 = words[wi + 1].t
          else
            t1 = line_t1
          end
          if t1 <= t0 then
            t1 = t0 + 0.05
          end
          segs[#segs + 1] = { t0 = t0, t1 = t1, text = join_words_range(ln, 1, k, sep) }
        end
      end
    else
      for _, g in ipairs(groups) do
        local toks = whitespace_tokens(g.display)
        local line_t1 = time_after_word_index(words, g.end_w, src_end)
        for k = 1, #toks do
          local wi = g.start_w + k - 1
          local t0 = words[wi].t
          local t1
          if wi < g.end_w then
            t1 = words[wi + 1].t
          else
            t1 = line_t1
          end
          if t1 <= t0 then
            t1 = t0 + 0.05
          end
          segs[#segs + 1] = { t0 = t0, t1 = t1, text = table.concat(toks, " ", 1, k) }
        end
      end
    end
    return segs
  end

  return segments_from_editor_groups(words, src_end, PRESET_WORD, groups, display_opts)
end

--- Each segment: { t0, t1, text } in source time. Second return is error string if editor text is invalid.
local function build_display_segments(words, src_end, display_opts)
  display_opts = display_opts or {}
  local et = display_opts.editor_text
  if type(et) == "string" and et ~= "" then
    local preset = display_opts.preset or PRESET_WORD
    if preset == PRESET_LINE_TRIPLE or preset == PRESET_LINE_STAIRS then
      local phrases, perr, phint = parse_editor_phrases_for_multiline(words, et, display_opts)
      if not phrases then
        return nil, perr, phint
      end
      return segments_from_phrases_multiline(words, src_end, preset, phrases, display_opts), nil, nil
    end
    local groups, perr, phint = parse_editor_line_groups(words, et)
    if not groups then
      return nil, perr, phint
    end
    return segments_from_editor_groups(words, src_end, preset, groups, display_opts), nil, nil
  end

  local preset = display_opts.preset or PRESET_WORD
  local karaoke = display_opts.karaoke and true or false
  if preset == PRESET_WORD then
    local segs = {}
    for i = 1, #words do
      local t0 = words[i].t
      local t1 = (i < #words) and words[i + 1].t or (src_end or (t0 + 2.0))
      if t1 <= t0 then
        t1 = t0 + 0.05
      end
      segs[#segs + 1] = { t0 = t0, t1 = t1, text = words[i].w, word_index = i }
    end
    return segs, nil, nil
  end
  local lines = split_words_into_lines(
    words,
    display_opts.words_per_line,
    display_opts.max_chars,
    display_opts.break_after_sentence and true or false
  )
  local join_sep = words_use_cjk_compact_join(words) and "" or " "
  local segs = {}
  local line_full_static = (preset == PRESET_LINE_FULL and not karaoke) or (preset == PRESET_LINE_GROW and not karaoke)
  local line_grow_motion = (preset == PRESET_LINE_FULL and karaoke) or (preset == PRESET_LINE_GROW and karaoke)

  if line_full_static then
    for li = 1, #lines do
      local ln = lines[li]
      local t0 = ln[1].t
      local last = ln[#ln]
      local t1
      if li < #lines then
        t1 = lines[li + 1][1].t
      else
        t1 = segment_t1_after_word(words, last, src_end)
      end
      if t1 <= t0 then
        t1 = t0 + 0.05
      end
      segs[#segs + 1] = { t0 = t0, t1 = t1, text = join_words_range(ln, 1, #ln, join_sep) }
    end
    return segs, nil, nil
  elseif line_grow_motion then
    for li = 1, #lines do
      local ln = lines[li]
      local line_t1
      if li < #lines then
        line_t1 = lines[li + 1][1].t
      else
        line_t1 = segment_t1_after_word(words, ln[#ln], src_end)
      end
      for i = 1, #ln do
        local t0 = ln[i].t
        local t1
        if i < #ln then
          t1 = ln[i + 1].t
        else
          t1 = line_t1
        end
        if t1 <= t0 then
          t1 = t0 + 0.05
        end
        segs[#segs + 1] = { t0 = t0, t1 = t1, text = join_words_range(ln, 1, i, join_sep) }
      end
    end
    return segs, nil, nil
  elseif preset == PRESET_LINE_TRIPLE or preset == PRESET_LINE_STAIRS then
    for li = 1, #lines do
      local ln = lines[li]
      local fg = fake_editor_group_from_slider_line(words, ln, join_sep)
      if fg then
        local disp = fg.display or ""
        local rows0 = split_phrase_on_pipe(disp)
        local cleaned = filter_nonempty_rows(rows0)
        if #cleaned < 1 then
          cleaned = { trim_display_line(disp) }
        end
        local max_r = math.max(1, math.min(6, math.floor(tonumber(display_opts.layout_max_rows) or 4)))
        local cjk2 = words_use_cjk_compact_join(words)
        local merged, mlim_err = apply_multiline_char_limit_then_merge(
          cleaned,
          words,
          fg.start_w,
          cjk2,
          max_r,
          cjk2 and "" or " ",
          display_opts,
          li
        )
        if not merged then
          return nil, "Subtitle line " .. li .. ": " .. tostring(mlim_err or "character limit failed."), nil
        end
        local row_end_w = {}
        if cjk2 then
          local j = fg.start_w
          for ri, rowtext in ipairs(merged) do
            local acc2 = ""
            local rtc = strip_overlay_grave(rowtext)
            while j <= fg.end_w do
              acc2 = acc2 .. words[j].w
              local a2c = strip_overlay_grave(acc2)
              if a2c == rtc then
                row_end_w[ri] = j
                j = j + 1
                break
              end
              if #a2c < #rtc and rtc:sub(1, #a2c) == a2c then
                j = j + 1
              else
                break
              end
            end
          end
        else
          local idx = fg.start_w
          for ri, rowtext in ipairs(merged) do
            local rt = whitespace_tokens(rowtext)
            if #rt > 0 then
              idx = idx + #rt
              row_end_w[ri] = idx - 1
            end
          end
        end
        local ph = {
          start_w = fg.start_w,
          end_w = fg.end_w,
          rows = merged,
          row_end_w = row_end_w,
          phrase_idx = li,
        }
        local seg = layout_segment_from_phrase(ph, words, src_end, preset, karaoke, display_opts)
        if seg then
          segs[#segs + 1] = seg
        end
      end
    end
    return segs, nil, nil
  else
    local o2 = {
      preset = PRESET_WORD,
      words_per_line = display_opts.words_per_line,
      max_chars = display_opts.max_chars,
      break_after_sentence = display_opts.break_after_sentence,
      editor_text = display_opts.editor_text,
      karaoke = display_opts.karaoke,
      layout_max_rows = display_opts.layout_max_rows,
      layout_line_scales = display_opts.layout_line_scales,
      layout_line_rand = display_opts.layout_line_rand,
      layout_line_gap = display_opts.layout_line_gap,
      layout_row_v_align = display_opts.layout_row_v_align,
      layout_rand_jitter = display_opts.layout_rand_jitter,
      layout_ml_row_chars = display_opts.layout_ml_row_chars,
      layout_ml_row_chars_rand = display_opts.layout_ml_row_chars_rand,
      layout_ml_chars_seed = display_opts.layout_ml_chars_seed,
      layout_indent_step = display_opts.layout_indent_step,
      layout_indent_rand = display_opts.layout_indent_rand,
      layout_indent_seed = display_opts.layout_indent_seed,
      anim_scope = display_opts.anim_scope,
      anim_in_on = display_opts.anim_in_on,
      anim_in_type = display_opts.anim_in_type,
      anim_in_curve = display_opts.anim_in_curve,
      anim_in_dur = display_opts.anim_in_dur,
      anim_in_amp = display_opts.anim_in_amp,
      anim_in_bounce = display_opts.anim_in_bounce,
      anim_in_motion = display_opts.anim_in_motion,
      anim_in_wiggle = display_opts.anim_in_wiggle,
      anim_in_scale = display_opts.anim_in_scale,
      anim_in_fade = display_opts.anim_in_fade,
      anim_in_blur = display_opts.anim_in_blur,
      anim_in_ghost = display_opts.anim_in_ghost,
      anim_in_dupes = display_opts.anim_in_dupes,
      anim_in_dir = display_opts.anim_in_dir,
      anim_in_twist = display_opts.anim_in_twist,
      anim_in_use_graph = display_opts.anim_in_use_graph,
      anim_in_graph = display_opts.anim_in_graph,
      anim_in_auto_blob = display_opts.anim_in_auto_blob,
      anim_in_graph_word_span = display_opts.anim_in_graph_word_span,
      anim_out_on = display_opts.anim_out_on,
      anim_out_type = display_opts.anim_out_type,
      anim_out_curve = display_opts.anim_out_curve,
      anim_out_dur = display_opts.anim_out_dur,
      anim_out_amp = display_opts.anim_out_amp,
      anim_phrase_out_on = display_opts.anim_phrase_out_on,
      anim_phrase_out_type = display_opts.anim_phrase_out_type,
      anim_phrase_out_curve = display_opts.anim_phrase_out_curve,
      anim_phrase_out_dur = display_opts.anim_phrase_out_dur,
      anim_phrase_out_amp = display_opts.anim_phrase_out_amp,
      anim_phrase_out_bounce = display_opts.anim_phrase_out_bounce,
      anim_phrase_out_motion = display_opts.anim_phrase_out_motion,
      anim_phrase_out_wiggle = display_opts.anim_phrase_out_wiggle,
      anim_phrase_out_scale = display_opts.anim_phrase_out_scale,
      anim_phrase_out_fade = display_opts.anim_phrase_out_fade,
      anim_phrase_out_blur = display_opts.anim_phrase_out_blur,
      anim_phrase_out_ghost = display_opts.anim_phrase_out_ghost,
      anim_phrase_out_dupes = display_opts.anim_phrase_out_dupes,
      anim_phrase_out_dir = display_opts.anim_phrase_out_dir,
      anim_phrase_out_twist = display_opts.anim_phrase_out_twist,
      anim_wipe_mask_offset = display_opts.anim_wipe_mask_offset,
      anim_phrase_out_use_graph = display_opts.anim_phrase_out_use_graph,
      anim_phrase_out_graph = display_opts.anim_phrase_out_graph,
      anim_phrase_out_auto_blob = display_opts.anim_phrase_out_auto_blob,
      anim_phrase_out_graph_word_span = display_opts.anim_phrase_out_graph_word_span,
      anim_out_bounce = display_opts.anim_out_bounce,
      anim_out_motion = display_opts.anim_out_motion,
      anim_out_wiggle = display_opts.anim_out_wiggle,
      anim_out_scale = display_opts.anim_out_scale,
      anim_out_fade = display_opts.anim_out_fade,
      anim_out_blur = display_opts.anim_out_blur,
      anim_out_ghost = display_opts.anim_out_ghost,
      anim_out_dupes = display_opts.anim_out_dupes,
      anim_out_dir = display_opts.anim_out_dir,
      anim_out_twist = display_opts.anim_out_twist,
      anim_out_use_graph = display_opts.anim_out_use_graph,
      anim_out_graph = display_opts.anim_out_graph,
      anim_out_auto_blob = display_opts.anim_out_auto_blob,
      anim_out_graph_word_span = display_opts.anim_out_graph_word_span,
      video_guides = display_opts.video_guides,
      word_styles = display_opts.word_styles,
      font_name = display_opts.font_name,
    }
    local s2, e2, h2 = build_display_segments(words, src_end, o2)
    return s2, e2, h2
  end
end

--- Append EEL for one triple-stack or stairs segment (variable rows, baked per-row font multipliers).
--- When `seg.word_per_gfx` and `display_opts.layout_word_scale` + `words` are set, each marker word is drawn with its own font scale.
local function append_layout_seg_eel(lines, seg, fontn, display_opts, words, anim_override_for_style)
  local rows = seg.rows or {}
  local n = math.min(6, #rows)
  if n < 1 then
    return
  end
  local mul = seg.row_mul or {}
  local tr = seg.t_rev_karaoke or {}
  local T0 = fmt_eel_num(seg.t0)
  local T1 = fmt_eel_num(seg.t1)
  local kf = seg.karaoke and "1" or "0"
  local fstr = '"' .. fontn .. '"'
  local function font_expr_for_row(row_text)
    return fstr
  end
  local lws = display_opts and display_opts.layout_word_scale
  local use_wl = seg.word_per_gfx and type(lws) == "table" and words and seg.row_start_w and seg.row_end_w
  local cjk = words and words_use_cjk_compact_join(words)
  local gap_eel = cjk and "0" or "floor(fs*0.1+0.5)"
  local anim_scope = math.floor(tonumber(display_opts and display_opts.anim_scope) or ANIM_SCOPE_EVERY_WORD)
  local anim = {
    in_on = display_opts and display_opts.anim_in_on,
    in_type = display_opts and display_opts.anim_in_type,
    in_curve = display_opts and display_opts.anim_in_curve,
    in_dur = display_opts and display_opts.anim_in_dur,
    in_amp = display_opts and display_opts.anim_in_amp,
    in_bounce = display_opts and display_opts.anim_in_bounce,
    in_motion = display_opts and display_opts.anim_in_motion,
    in_wiggle = display_opts and display_opts.anim_in_wiggle,
    in_scale = display_opts and display_opts.anim_in_scale,
    in_fade = display_opts and display_opts.anim_in_fade,
    in_blur = display_opts and display_opts.anim_in_blur,
    in_ghost = display_opts and display_opts.anim_in_ghost,
    in_dupes = display_opts and display_opts.anim_in_dupes,
    in_dir = display_opts and display_opts.anim_in_dir,
    in_twist = display_opts and display_opts.anim_in_twist,
    wipe_mask_offset = display_opts and display_opts.anim_wipe_mask_offset,
    in_use_graph = display_opts and display_opts.anim_in_use_graph,
    in_graph = display_opts and display_opts.anim_in_graph,
    in_graph_word_span = display_opts and display_opts.anim_in_graph_word_span,
    in_auto_blob = display_opts and display_opts.anim_in_auto_blob,
    out_on = display_opts and display_opts.anim_out_on,
    out_type = display_opts and display_opts.anim_out_type,
    out_curve = display_opts and display_opts.anim_out_curve,
    out_dur = display_opts and display_opts.anim_out_dur,
    out_amp = display_opts and display_opts.anim_out_amp,
    out_bounce = display_opts and display_opts.anim_out_bounce,
    out_motion = display_opts and display_opts.anim_out_motion,
    out_wiggle = display_opts and display_opts.anim_out_wiggle,
    out_scale = display_opts and display_opts.anim_out_scale,
    out_fade = display_opts and display_opts.anim_out_fade,
    out_blur = display_opts and display_opts.anim_out_blur,
    out_ghost = display_opts and display_opts.anim_out_ghost,
    out_dupes = display_opts and display_opts.anim_out_dupes,
    out_dir = display_opts and display_opts.anim_out_dir,
    out_twist = display_opts
      and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_twist) or display_opts.anim_out_twist),
    wipe_mask_offset = display_opts and display_opts.anim_wipe_mask_offset,
    out_use_graph = display_opts
      and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_use_graph) or display_opts.anim_out_use_graph),
    out_graph = display_opts
      and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_graph) or display_opts.anim_out_graph),
    out_auto_blob = display_opts
      and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_auto_blob) or display_opts.anim_out_auto_blob),
    out_graph_word_span = display_opts
      and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_graph_word_span) or display_opts.anim_out_graph_word_span),
  }
  local phrase_start_w = tonumber(seg.phrase_start_w) or ((seg.row_start_w and seg.row_start_w[1]) or 1)
  local phrase_out_on = display_opts and display_opts.anim_phrase_out_on

  lines[#lines + 1] = string.format("(src >= %s && src < %s) ? (", T0, T1)
  lines[#lines + 1] = "  kf=" .. kf .. "; stf=0;"
  lines[#lines + 1] = "  fs=floor(fontPx+0.5);"
  for i = 1, n do
    local m = tonumber(mul[i]) or 1
    lines[#lines + 1] = string.format("  fs%d=max(8,floor(fs*%.17g+0.5));", i, m)
  end
  if use_wl then
    for i = 1, n do
      local rs = seg.row_start_w[i]
      local re = seg.row_end_w[i]
      lines[#lines + 1] = string.format("  tw%d=0; th%d=8;", i, i)
      if rs and re and rs <= re then
        for wi = rs, re do
          local lit = escape_eel_dq_string(words[wi].w or "")
          local sc = tonumber(lws[wi]) or 1
          local m = tonumber(mul[i]) or 1
          local st = word_style_for(display_opts, wi)
          local wfstr = word_style_font_expr_for_text(fontn, st, words[wi].w or "")
          lines[#lines + 1] = string.format(
            "  gfx_setfont(max(8,floor(fs*%.17g*%.17g+0.5)),%s); gfx_str_measure(\"%s\",twm,thm); tw%d+=twm+%s; th%d=max(th%d,thm);",
            m,
            sc,
            wfstr,
            lit,
            i,
            gap_eel,
            i,
            i
          )
        end
      end
    end
  else
    for i = 1, n do
      local ew = escape_eel_dq_string(rows[i] or "")
      lines[#lines + 1] = string.format("  gfx_setfont(fs%d,%s);", i, font_expr_for_row(rows[i] or ""))
      lines[#lines + 1] = string.format('  gfx_str_measure("%s",tw%d,th%d);', ew, i, i)
    end
  end
  local gpm = tonumber(seg.line_gap_mul) or 0.1
  gpm = math.max(-0.95, math.min(0.5, gpm))
  local rgm = seg.row_gap_mul
  local v_align = math.max(0, math.min(2, math.floor(tonumber(seg.row_v_align) or 0)))
  local v_mul = (v_align == 1) and "0.5" or ((v_align == 2) and "1" or "0")
  lines[#lines + 1] = "  gap=floor(fs*" .. fmt_eel_num(gpm) .. "+0.5); cy=posY*project_h; cx=posX*project_w;"
  if type(rgm) == "table" then
    for i = 2, n do
      local gv = math.max(-0.95, math.min(1.5, tonumber(rgm[i]) or gpm))
      lines[#lines + 1] = string.format("  gap%d=floor(fs*%s+0.5);", i, fmt_eel_num(gv))
    end
  end
  local totex = "th1"
  for i = 2, n do
    totex = totex .. "+th" .. i
  end
  if n > 1 then
    if type(rgm) == "table" then
      for i = 2, n do
        totex = totex .. "+gap" .. i
      end
    else
      totex = totex .. "+gap*" .. (n - 1)
    end
  end
  lines[#lines + 1] = "  tot=" .. totex .. ";"
  lines[#lines + 1] = "  ytop=cy-tot*0.5;"
  lines[#lines + 1] = "  y1=ytop;"
  for i = 2, n do
    local gap_var = (type(rgm) == "table") and ("gap" .. i) or "gap"
    lines[#lines + 1] = string.format("  y%d=y%d+th%d+%s;", i, i - 1, i - 1, gap_var)
  end
  local rxf = seg.row_x_frac or {}
  for i = 1, n do
    local oxf = tonumber(rxf[i]) or 0
    oxf = math.max(-0.5, math.min(0.5, oxf))
    lines[#lines + 1] = string.format("  x%d=cx+%s*project_w-tw%d*0.5;", i, fmt_eel_num(oxf), i)
  end
  append_anim_eel(lines, "ph_", T0, T1, {
    in_on = false,
    out_on = phrase_out_on,
    out_type = display_opts and (display_opts.anim_phrase_out_type or display_opts.anim_out_type),
    out_curve = display_opts and (display_opts.anim_phrase_out_curve or display_opts.anim_out_curve),
    out_dur = display_opts and (display_opts.anim_phrase_out_dur or display_opts.anim_out_dur),
    out_amp = display_opts and (display_opts.anim_phrase_out_amp or display_opts.anim_out_amp),
    out_bounce = display_opts and (display_opts.anim_phrase_out_bounce or display_opts.anim_out_bounce),
    out_motion = display_opts and (display_opts.anim_phrase_out_motion or display_opts.anim_out_motion),
    out_wiggle = display_opts and (display_opts.anim_phrase_out_wiggle or display_opts.anim_out_wiggle),
    out_scale = display_opts and (display_opts.anim_phrase_out_scale or display_opts.anim_out_scale),
    out_fade = display_opts and (display_opts.anim_phrase_out_fade or display_opts.anim_out_fade),
    out_blur = display_opts and (display_opts.anim_phrase_out_blur or display_opts.anim_out_blur),
    out_ghost = display_opts and (display_opts.anim_phrase_out_ghost or display_opts.anim_out_ghost),
    out_dupes = display_opts and (display_opts.anim_phrase_out_dupes or display_opts.anim_out_dupes),
    out_dir = display_opts and (display_opts.anim_phrase_out_dir or display_opts.anim_out_dir),
    out_twist = display_opts and (display_opts.anim_phrase_out_twist or display_opts.anim_out_twist),
    wipe_mask_offset = display_opts and display_opts.anim_wipe_mask_offset,
    out_use_graph = display_opts and (display_opts.anim_phrase_out_use_graph or display_opts.anim_out_use_graph),
    out_graph = display_opts and (display_opts.anim_phrase_out_graph or display_opts.anim_out_graph),
    out_auto_blob = display_opts and (display_opts.anim_phrase_out_auto_blob or display_opts.anim_out_auto_blob),
    out_graph_word_span = display_opts and (display_opts.anim_phrase_out_graph_word_span or display_opts.anim_out_graph_word_span),
  })
  lines[#lines + 1] = "  a1=1;"
  for i = 2, n do
    local T = tr[i - 1] and fmt_eel_num(tr[i - 1]) or T0
    lines[#lines + 1] = string.format("  a%d=(kf < 0.5) ? (1) : ((src >= %s) ? (1) : (0.45));", i, T)
  end
  local kvis = seg.row_karaoke_vis_eel
  for i = 1, n do
    local ew = escape_eel_dq_string(rows[i] or "")
    if use_wl then
      local rs = seg.row_start_w[i]
      local re = seg.row_end_w[i]
      lines[#lines + 1] = string.format("  xw=x%d;", i)
      if rs and re and rs <= re then
        for wi = rs, re do
          local lit = escape_eel_dq_string(words[wi].w or "")
          local sc = tonumber(lws[wi]) or 1
          local m = tonumber(mul[i]) or 1
          local Tw = fmt_eel_num(words[wi].t)
          local Tw1 = fmt_eel_num(time_after_word_index(words, wi, seg.t1))
          local pfx = "aw" .. tostring(wi) .. "_"
          local st = word_style_for(display_opts, wi)
          local anim_override = anim_override_for_style and anim_override_for_style(st) or nil
          local anim_cfg = anim_override or anim
          local apply_anim = (anim_scope == ANIM_SCOPE_EVERY_WORD)
          if anim_scope == ANIM_SCOPE_PHRASE_FIRST then
            apply_anim = wi == phrase_start_w
          elseif anim_scope == ANIM_SCOPE_ROW_FIRST then
            apply_anim = wi == rs
          end
          if anim_override then
            apply_anim = true
          end
          local fsw_e = string.format("max(8,floor(fs*%.17g*%.17g+0.5))", m, sc)
          if apply_anim then
            append_anim_eel(lines, pfx, Tw, Tw1, anim_cfg)
          else
            lines[#lines + 1] = string.format("  %sa=1; %ss=1; %sdx=0; %sdy=0; %sr=0;", pfx, pfx, pfx, pfx, pfx)
          end
          local fsw_draw = string.format("max(8,floor((%s)*%ss*ph_s+0.5))", fsw_e, pfx)
          local base_alpha = (i == 1) and "1" or ("a" .. i)
          local draw_x = string.format("floor(xw+%sdx+ph_dx+0.5)", pfx)
          local draw_y = string.format("floor(y%d+(th%d-thm)*%s+%sdy+ph_dy+0.5)", i, i, v_mul, pfx)
          local draw_a = string.format("%s*%sa*ph_a", base_alpha, pfx)
          local wfstr = word_style_font_expr_for_text(fontn, st, words[wi].w or "")
          local draw_anim_pfx = phrase_out_on and "ph_" or (apply_anim and pfx or nil)
          local draw_image_mask = (apply_anim and anim_cfg_needs_image_mask(anim_cfg)) or false
          local rot_glue = nil
          if phrase_out_on and apply_anim then
            rot_glue = pfx .. "r+ph_r"
            draw_image_mask = draw_image_mask or anim_cfg_needs_image_mask({
              out_on = phrase_out_on,
              out_type = display_opts and (display_opts.anim_phrase_out_type or display_opts.anim_out_type),
            })
          elseif phrase_out_on then
            rot_glue = "ph_r"
            draw_image_mask = anim_cfg_needs_image_mask({
              out_on = phrase_out_on,
              out_type = display_opts and (display_opts.anim_phrase_out_type or display_opts.anim_out_type),
            })
          elseif apply_anim then
            rot_glue = pfx .. "r"
          end
          if seg.karaoke then
            lines[#lines + 1] = string.format('  (src < %s) ? strcpy(#wxov_tmp,"") : strcpy(#wxov_tmp,"%s"); gfx_setfont(%s,%s); gfx_str_measure(#wxov_tmp,twm,thm); (twm>0)?(', Tw, lit, fsw_draw, wfstr)
            append_styled_text_draw(lines, "#wxov_tmp", draw_x, draw_y, "twm", "thm", draw_a, st, draw_anim_pfx, rot_glue, draw_image_mask)
            lines[#lines + 1] = "    xw+=twm+" .. gap_eel .. ";"
            lines[#lines + 1] = "  );"
          else
            lines[#lines + 1] = string.format('  gfx_setfont(%s,%s); gfx_str_measure("%s",twm,thm);', fsw_draw, wfstr, lit)
            append_styled_text_draw(lines, '"' .. lit .. '"', draw_x, draw_y, "twm", "thm", draw_a, st, draw_anim_pfx, rot_glue, draw_image_mask)
            lines[#lines + 1] = "  xw+=twm+" .. gap_eel .. ";"
          end
        end
      end
    elseif kvis and kvis[i] then
      local slot = "#wxov_ml" .. i
      local pfx = "ar" .. tostring(i) .. "_"
      local row_fstr = font_expr_for_row(rows[i] or "")
      local rs = seg.row_start_w and seg.row_start_w[i]
      local re = seg.row_end_w and seg.row_end_w[i]
      local row_t0 = (rs and words and words[rs] and fmt_eel_num(words[rs].t)) or T0
      local row_t1 = (re and words and fmt_eel_num(time_after_word_index(words, re, seg.t1))) or T1
      local apply_anim = (anim_scope ~= ANIM_SCOPE_PHRASE_FIRST) or (i == 1)
      if apply_anim then
        append_anim_eel(lines, pfx, row_t0, row_t1, anim)
      else
        lines[#lines + 1] = string.format("  %sa=1; %ss=1; %sdx=0; %sdy=0;", pfx, pfx, pfx, pfx)
      end
      lines[#lines + 1] = string.format(
        "  %s; gfx_setfont(max(8,floor(fs%d*%ss*ph_s+0.5)),%s); gfx_str_measure(%s,twk%d,thk%d); (twk%d>0)?(gfx_set(a%d*%sa*ph_a,a%d*%sa*ph_a,a%d*%sa*ph_a,1); gfx_str_draw(%s,floor(x%d+%sdx+ph_dx+0.5),floor(y%d+%sdy+ph_dy+0.5)));",
        kvis[i],
        i,
        pfx,
        row_fstr,
        slot,
        i,
        i,
        i,
        i,
        pfx,
        i,
        pfx,
        i,
        pfx,
        slot,
        i,
        pfx,
        i,
        pfx
      )
    else
      local pfx = "ar" .. tostring(i) .. "_"
      local row_fstr = font_expr_for_row(rows[i] or "")
      local rs = seg.row_start_w and seg.row_start_w[i]
      local re = seg.row_end_w and seg.row_end_w[i]
      local row_t0 = (rs and words and words[rs] and fmt_eel_num(words[rs].t)) or T0
      local row_t1 = (re and words and fmt_eel_num(time_after_word_index(words, re, seg.t1))) or T1
      local apply_anim = (anim_scope ~= ANIM_SCOPE_PHRASE_FIRST) or (i == 1)
      if apply_anim then
        append_anim_eel(lines, pfx, row_t0, row_t1, anim)
      else
        lines[#lines + 1] = string.format("  %sa=1; %ss=1; %sdx=0; %sdy=0;", pfx, pfx, pfx, pfx)
      end
      lines[#lines + 1] = string.format(
        '  (tw%d>0)?(gfx_set(a%d*%sa*ph_a,a%d*%sa*ph_a,a%d*%sa*ph_a,1); gfx_setfont(max(8,floor(fs%d*%ss*ph_s+0.5)),%s); gfx_str_draw("%s",floor(x%d+%sdx+ph_dx+0.5),floor(y%d+%sdy+ph_dy+0.5)));',
        i,
        i,
        pfx,
        i,
        pfx,
        i,
        pfx,
        i,
        pfx,
        row_fstr,
        ew,
        i,
        pfx,
        i
        ,
        pfx
      )
    end
  end
  lines[#lines + 1] = ");"
end

local function append_video_ratio_guides_eel(lines, guides)
  if type(guides) ~= "table" or #guides == 0 then
    return
  end
  lines[#lines + 1] = "vg_t=max(2,floor(wxov_vh*0.004+0.5));"
  for i = 1, #guides do
    local g = guides[i]
    local ratio = tonumber(g and g.ratio)
    if ratio and ratio > 0 then
      local rr, gg, bb = rgb_eel_parts((g and g.color) or 0xFFFFFF)
      lines[#lines + 1] = string.format(
        "vg_r=%s; vg_w=wxov_vw; vg_h=wxov_vh; (wxov_vw/wxov_vh > vg_r) ? (vg_h=wxov_vh; vg_w=vg_h*vg_r;) : (vg_w=wxov_vw; vg_h=vg_w/vg_r;); vg_x=wxov_vx+floor((wxov_vw-vg_w)*0.5+0.5); vg_y=wxov_vy+floor((wxov_vh-vg_h)*0.5+0.5); gfx_set(%s,%s,%s,0.88); gfx_fillrect(vg_x,vg_y,vg_w,vg_t); gfx_fillrect(vg_x,vg_y+vg_h-vg_t,vg_w,vg_t); gfx_fillrect(vg_x,vg_y,vg_t,vg_h); gfx_fillrect(vg_x+vg_w-vg_t,vg_y,vg_t,vg_h);",
        fmt_eel_num(ratio),
        rr,
        gg,
        bb
      )
    end
  end
end

local function image_post_wave_opts(display_opts)
  if not display_opts or not display_opts.img_post_wave then
    return nil
  end
  local amp = math.max(0, math.min(240, tonumber(display_opts.img_post_wave_amp) or 24))
  if amp <= 0 then
    return nil
  end
  local len = math.max(8, math.min(2000, tonumber(display_opts.img_post_wave_len) or 90))
  local speed = math.max(-20, math.min(20, tonumber(display_opts.img_post_wave_speed) or 6))
  return amp, len, speed
end

local function append_image_post_wave_begin_eel(lines, display_opts)
  local amp = image_post_wave_opts(display_opts)
  if not amp then
    return false
  end
  lines[#lines + 1] = "colorspace='RGBA'; wxov_post_old_dest=gfx_dest; wxov_post=max(0,floor(wxov_post+0.5))<1 ? gfx_img_alloc(project_w, project_h, 1) : gfx_img_resize(wxov_post, project_w, project_h, 1); gfx_dest=wxov_post; gfx_mode=0; gfx_set(0,1,0,1); gfx_fillrect(0,0,project_w,project_h);"
  return true
end

local function append_image_post_wave_end_eel(lines, display_opts)
  local amp, len, speed = image_post_wave_opts(display_opts)
  if not amp then
    return
  end
  lines[#lines + 1] = 'gfx_evalrect(0,0,project_w,project_h,"((g>220) && (r<80) && (b<80)) ? (a=0;) : (a=255;);");'
  lines[#lines + 1] = "gfx_set(1,1,1,1,0x10000,wxov_post_old_dest);"
  lines[#lines + 1] = string.format(
    "wxov_wave_amp=%s; wxov_wave_len=%s; wxov_wave_speed=%s; wxov_wave_slice=max(2,floor(project_h/160+0.5)); wxov_wave_n=floor((project_h+wxov_wave_slice-1)/wxov_wave_slice); wxov_wave_y=0; loop(wxov_wave_n, wxov_wave_h=min(wxov_wave_slice,project_h-wxov_wave_y); wxov_wave_dx=floor(sin(wxov_wave_y/wxov_wave_len + time*wxov_wave_speed)*wxov_wave_amp+0.5); gfx_blit(wxov_post,0,wxov_wave_dx,wxov_wave_y,project_w,wxov_wave_h,0,wxov_wave_y,project_w,wxov_wave_h); wxov_wave_y+=wxov_wave_slice;);",
    fmt_eel_num(amp),
    fmt_eel_num(len),
    fmt_eel_num(speed)
  )
  lines[#lines + 1] = "gfx_mode=0; gfx_a=1;"
end

--- display_opts: { preset, words_per_line, max_chars, break_after_sentence, karaoke, editor_text }
local function build_eel_body(words, src_end, startoffs, playrate, display_opts)
  if #words == 0 then
    return nil, "No take markers with text on the active take."
  end
  if #words > MAX_WORDS then
    return nil, "Too many words (" .. #words .. "). Max " .. MAX_WORDS .. " for this script."
  end

  local segs, serr = build_display_segments(words, src_end, display_opts)
  if not segs then
    return nil, serr or "Display build failed."
  end
  if #segs > MAX_WORDS then
    return nil, "Too many overlay segments (" .. #segs .. "). Max " .. MAX_WORDS .. "."
  end

  local lines = {}
  lines[#lines + 1] = "// " .. SENTINEL .. " - WhisperX word overlay"
  lines[#lines + 1] = '//@param 1:posX "Position X (0=left 1=right)" 0.5 0 1 0.5 0.01'
  lines[#lines + 1] = '//@param 2:posY "Position Y (0=top 1=bottom)" 0.5 0 1 0.5 0.01'
  lines[#lines + 1] = '//@param 3:fontPx "Font size (px)" 70 10 200 70 1'
  lines[#lines + 1] = '//@param 4:midScale "Triple: middle line scale" 2 1.2 3 2 0.02'
  lines[#lines + 1] = '//@param 5:stairStep "(unused legacy) row indent is baked in bridge" 0.04 0 0.2 0.04 0.002'
  lines[#lines + 1] = string.format(
    '//@param 6:wipeMaskOffset "Wipe mask offset px" %s -300 300 0 1',
    fmt_eel_num((display_opts and display_opts.anim_wipe_mask_offset) or 0)
  )
  lines[#lines + 1] = "SO=" .. fmt_eel_num(startoffs) .. ";"
  lines[#lines + 1] = "PR=" .. fmt_eel_num(playrate) .. ";"
  lines[#lines + 1] = "iw=0; ih=0;"
  lines[#lines + 1] = "input_info(0, iw, ih);"
  lines[#lines + 1] = "wxov_vx=0; wxov_vy=0; wxov_vw=project_w; wxov_vh=project_h; ((iw>0) && (ih>0) && (project_w>0) && (project_h>0)) ? (wxov_ir=iw/ih; wxov_pr=project_w/project_h; (wxov_pr>wxov_ir) ? (wxov_vh=project_h; wxov_vw=floor(wxov_vh*wxov_ir+0.5); wxov_vx=floor((project_w-wxov_vw)*0.5+0.5);) : (wxov_vw=project_w; wxov_vh=floor(wxov_vw/wxov_ir+0.5); wxov_vy=floor((project_h-wxov_vh)*0.5+0.5);););"
  lines[#lines + 1] = "gfx_blit(0, 0, 0, 0, project_w, project_h); wxov_spin=floor(wxov_spin+0.5); wxov_ol0=floor(wxov_ol0+0.5); wxov_ol1=floor(wxov_ol1+0.5); wxov_ol2=floor(wxov_ol2+0.5); wxov_ol3=floor(wxov_ol3+0.5);"
  append_video_ratio_guides_eel(lines, display_opts and display_opts.video_guides)
  lines[#lines + 1] = "src=SO+time*PR;"
  lines[#lines + 1] = "txtw=0; txth=0;"
  local picked_font = trim_display_line(display_opts and display_opts.font_name or "")
  if picked_font == "" then
    picked_font = default_vp_gfx_font()
  end
  local fontn = escape_eel_dq_string(picked_font)
  local anim_preset_cache = {}
  local function anim_override_for_style(st)
    if type(st) ~= "table" then
      return nil
    end
    local nm = trim_display_line(st.anim_preset_name or "")
    if nm == "" then
      return nil
    end
    if anim_preset_cache[nm] ~= nil then
      return anim_preset_cache[nm]
    end
    local blob = r.GetExtState("BRYAN_WX_OVERLAY_UI", anim_preset_key(nm))
    local parsed = parse_anim_preset_blob(blob or "")
    anim_preset_cache[nm] = parsed or false
    return parsed
  end
  lines[#lines + 1] = "gfx_setfont(floor(fontPx+0.5),\"" .. fontn .. "\");"
  lines[#lines + 1] = "gfx_set(1, 1, 1, 1, 0);"
  lines[#lines + 1] = "gfx_mode=0;"
  local image_post_wave = append_image_post_wave_begin_eel(lines, display_opts)

  for i = 1, #segs do
    local seg = segs[i]
    local t0 = seg.t0
    local t1 = seg.t1
    if t1 <= t0 then
      t1 = t0 + 0.05
    end
    if seg.layout == "triple" or seg.layout == "stairs" then
      append_layout_seg_eel(lines, seg, fontn, display_opts, words, anim_override_for_style)
    else
      local ew = escape_eel_dq_string(seg.text)
      local T0s = fmt_eel_num(t0)
      local T1s = fmt_eel_num(t1)
      lines[#lines + 1] = string.format("(src >= %s && src < %s) ? (", T0s, T1s)
      lines[#lines + 1] = "  as_a=1; as_s=1; as_dx=0; as_dy=0;"
      local st = word_style_for(display_opts, seg.word_index)
      local anim_override = anim_override_for_style(st)
      local seg_anim_cfg = anim_override or {
        in_on = display_opts and display_opts.anim_in_on,
        in_type = display_opts and display_opts.anim_in_type,
        in_curve = display_opts and display_opts.anim_in_curve,
        in_dur = display_opts and display_opts.anim_in_dur,
        in_amp = display_opts and display_opts.anim_in_amp,
        in_bounce = display_opts and display_opts.anim_in_bounce,
        in_motion = display_opts and display_opts.anim_in_motion,
        in_wiggle = display_opts and display_opts.anim_in_wiggle,
        in_scale = display_opts and display_opts.anim_in_scale,
        in_fade = display_opts and display_opts.anim_in_fade,
        in_blur = display_opts and display_opts.anim_in_blur,
        in_ghost = display_opts and display_opts.anim_in_ghost,
        in_dupes = display_opts and display_opts.anim_in_dupes,
        in_dir = display_opts and display_opts.anim_in_dir,
        in_twist = display_opts and display_opts.anim_in_twist,
        wipe_mask_offset = display_opts and display_opts.anim_wipe_mask_offset,
        in_use_graph = display_opts and display_opts.anim_in_use_graph,
        in_graph = display_opts and display_opts.anim_in_graph,
        in_graph_word_span = display_opts and display_opts.anim_in_graph_word_span,
        in_auto_blob = display_opts and display_opts.anim_in_auto_blob,
        out_on = display_opts and (display_opts.anim_out_on or display_opts.anim_phrase_out_on),
        out_type = display_opts and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_type) or display_opts.anim_out_type),
        out_curve = display_opts and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_curve) or display_opts.anim_out_curve),
        out_dur = display_opts and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_dur) or display_opts.anim_out_dur),
        out_amp = display_opts and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_amp) or display_opts.anim_out_amp),
        out_bounce = display_opts and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_bounce) or display_opts.anim_out_bounce),
        out_motion = display_opts and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_motion) or display_opts.anim_out_motion),
        out_wiggle = display_opts and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_wiggle) or display_opts.anim_out_wiggle),
        out_scale = display_opts and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_scale) or display_opts.anim_out_scale),
        out_fade = display_opts and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_fade) or display_opts.anim_out_fade),
        out_blur = display_opts and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_blur) or display_opts.anim_out_blur),
        out_ghost = display_opts and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_ghost) or display_opts.anim_out_ghost),
        out_dupes = display_opts and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_dupes) or display_opts.anim_out_dupes),
        out_dir = display_opts and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_dir) or display_opts.anim_out_dir),
        out_twist = display_opts
          and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_twist) or display_opts.anim_out_twist),
        wipe_mask_offset = display_opts and display_opts.anim_wipe_mask_offset,
        out_use_graph = display_opts
          and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_use_graph) or display_opts.anim_out_use_graph),
        out_graph = display_opts
          and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_graph) or display_opts.anim_out_graph),
        out_auto_blob = display_opts
          and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_auto_blob) or display_opts.anim_out_auto_blob),
        out_graph_word_span = display_opts
          and ((display_opts.anim_phrase_out_on and display_opts.anim_phrase_out_graph_word_span) or display_opts.anim_out_graph_word_span),
      }
      append_anim_eel(lines, "as_", T0s, T1s, seg_anim_cfg)
      local sfnt = word_style_font_expr_for_text(fontn, st, seg.text or "")
      lines[#lines + 1] = string.format(
        '  gfx_setfont(max(8,floor(fontPx*as_s+0.5)),%s); gfx_str_measure("%s", txtw, txth); x = floor(posX * project_w - txtw * 0.5 + as_dx + 0.5); y = floor(posY * project_h - txth * 0.5 + as_dy + 0.5);',
        sfnt,
        ew
      )
      append_styled_text_draw(lines, '"' .. ew .. '"', "x", "y", "txtw", "txth", "as_a", st, "as_", "as_r", anim_cfg_needs_image_mask(seg_anim_cfg))
      lines[#lines + 1] = ");"
    end
  end

  if image_post_wave then
    append_image_post_wave_end_eel(lines, display_opts)
  end

  return table.concat(lines, "\n"), nil
end

--- REAPER .rpp / item chunks store Video Processor EEL with spaces + tab + '|' on each line (ReaTeam state chunk spec).
--- Without it, the FX editor often shows an empty preset and the effect does nothing.
local VP_CODE_LINE_PREFIX = "   \t|"

local function eel_plain_to_reaper_vp_chunk(plain)
  if not plain or plain == "" then
    return ""
  end
  local out = {}
  for line in (plain .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    out[#out + 1] = VP_CODE_LINE_PREFIX .. line
  end
  -- Must end with newline: replace_video_processor_code appends the original ">"/CODEPARM suffix;
  -- without \n the last CODE line and the ">" line merge and SetItemStateChunk fails.
  local s = table.concat(out, "\n")
  if s:sub(-1) ~= "\n" then
    s = s .. "\n"
  end
  return s
end

--- Match FXID in item chunk (brace-insensitive, case-insensitive).
local function fx_guid_chunk_needle(guid)
  if type(guid) ~= "string" or guid == "" then
    return nil
  end
  local inner = guid:match("^{(.+)}$") or guid
  inner = inner:lower():gsub("%s+", "")
  if inner == "" then
    return nil
  end
  return inner
end

--- When an item has several takes, each can have a Video processor; the chunk order need not match "last = active take".
--- After TakeFX_AddByName, the new instance's GUID appears only in that take's VIDEO_EFFECT block.
local function find_video_effect_block_start_for_guid(chunk, guid)
  local needle = fx_guid_chunk_needle(guid)
  if not needle then
    return nil
  end
  local starts = {}
  local p = 1
  while true do
    local s = chunk:find("<VIDEO_EFFECT", p, true)
    if not s then
      break
    end
    starts[#starts + 1] = s
    p = s + 1
  end
  local lowchunk = chunk:lower()
  for i = 1, #starts do
    local a = starts[i]
    local b = (starts[i + 1] or (#chunk + 1)) - 1
    if lowchunk:sub(a, b):find(needle, 1, true) then
      return a
    end
  end
  return nil
end

--- Split s into lines; seps[i] is newline length (\1 or \2) after lines[i].
local function split_lines_crlf(s)
  local lines, seps = {}, {}
  local i = 1
  while i <= #s do
    local crlf = s:find("\r\n", i, true)
    local lf = s:find("\n", i, true)
    local cr = s:find("\r", i, true)
    local j, nlen
    if crlf and (not lf or crlf <= lf) and (not cr or crlf <= cr) then
      j, nlen = crlf, 2
    elseif lf and (not cr or lf <= cr) then
      j, nlen = lf, 1
    elseif cr then
      j, nlen = cr, 1
    else
      lines[#lines + 1] = s:sub(i)
      seps[#seps + 1] = 0
      break
    end
    lines[#lines + 1] = s:sub(i, j - 1)
    seps[#seps + 1] = nlen
    i = j + nlen
  end
  return lines, seps
end

local function line_byte_start(lines, seps, line_idx)
  local hpos = 1
  for j = 1, line_idx - 1 do
    hpos = hpos + #lines[j] + (seps[j] or 0)
  end
  return hpos
end

--- True if this line is the Video Processor "</CODE>" closer (REAPER uses a lone '>' line).
local function vp_line_closes_block(line)
  if not line or line == "" then
    return false
  end
  line = line:gsub("\r", "")
  line = line:gsub("\239\188\158", ">")
  local t = line:gsub("^[\t |]+", ""):gsub("[\t ]+$", "")
  if t == ">" then
    return true
  end
  if t:match("^>%s*//") or t:match("^>%s*$") then
    return true
  end
  if t:match("^|+>%s*//") or t:match("^|+>%s*$") then
    return true
  end
  if t:match("^|+%s+>%s*//") or t:match("^|+%s+>%s*$") then
    return true
  end
  return false
end

--- Whole region is only the closer (empty preset / minimal chunk).
local function head_region_is_solo_close(head_region)
  local hr = head_region:gsub("\r\n", "\n"):gsub("\r", "\n")
  hr = hr:gsub("\239\188\158", ">")
  hr = hr:gsub("^[\t \n]+", ""):gsub("[\t \n]+$", "")
  return hr == ">" or hr == "|>" or vp_line_closes_block(hr)
end

--- First index in chunk (>= from_pos) where "CODEPARM" starts (case-insensitive, not inside a longer id).
local function find_codeparm_token(chunk, from_pos)
  local low = chunk:lower()
  local p = from_pos
  local maxp = #chunk - 7
  while p <= maxp do
    if low:sub(p, p + 7) == "codeparm" then
      local prev = p > 1 and chunk:sub(p - 1, p - 1) or " "
      if not prev:match("%a") then
        return p
      end
    end
    p = p + 1
  end
  return nil
end

--- Replace inner text of <CODE ... > for the VIDEO_EFFECT block that contains `prefer_fx_guid`,
--- else the block that contains `sentinel`, else the last VIDEO_EFFECT in the chunk.
local function replace_video_processor_code(chunk, new_inner, sentinel, prefer_fx_guid)
  local anchor = sentinel and chunk:find(sentinel, 1, true) or nil
  local search_from = 1
  local last_open = nil
  while true do
    local s = chunk:find("<VIDEO_EFFECT", search_from, true)
    if not s then
      break
    end
    last_open = s
    search_from = s + 1
  end
  if not last_open and not anchor then
    return nil, "No <VIDEO_EFFECT in item chunk."
  end
  local block_start
  local by_guid = find_video_effect_block_start_for_guid(chunk, prefer_fx_guid)
  if by_guid then
    block_start = by_guid
  elseif anchor then
    local head = chunk:sub(1, anchor)
    block_start = 0
    local p = 1
    while true do
      local s = head:find("<VIDEO_EFFECT", p, true)
      if not s then
        break
      end
      block_start = s
      p = s + 1
    end
    if block_start == 0 then
      block_start = last_open
    end
  else
    block_start = last_open
  end
  if not block_start then
    return nil, "Could not locate VIDEO_EFFECT block."
  end
  local tail = chunk:sub(block_start)
  local tail_low = tail:lower()
  local cs = tail_low:find("<code", 1, true)
  if not cs then
    return nil, "No <CODE in VIDEO_EFFECT."
  end
  -- tail[cs] is '<'; "<CODE" is 5 bytes; body starts at tail index cs+5.
  local after_tag = block_start + cs + 5 - 1
  local tag_rest = chunk:sub(after_tag, math.min(#chunk, after_tag + 256))
  local nl_rel = tag_rest:find("[\r\n]", 1)
  if not nl_rel then
    return nil, "No newline after <CODE tag."
  end
  local nl = after_tag + nl_rel - 1
  local code_inner_start
  if chunk:sub(nl, nl + 1) == "\r\n" then
    code_inner_start = nl + 2
  else
    code_inner_start = nl + 1
  end

  local cp = find_codeparm_token(chunk, code_inner_start)
  if not cp then
    local ex = chunk:sub(block_start, math.min(#chunk, block_start + 1800))
    return nil, "No CODEPARM token after <CODE (unexpected Video Processor chunk).", ex
  end

  local head_region = chunk:sub(code_inner_start, cp - 1)
  head_region = head_region:gsub("[\t ]+$", "")
  head_region = head_region:gsub("[\r\n]+$", "")

  local lines, seps = split_lines_crlf(head_region)
  local gt_line_idx = nil
  for li = #lines, 1, -1 do
    if vp_line_closes_block(lines[li]) then
      gt_line_idx = li
      break
    end
  end
  if not gt_line_idx and head_region_is_solo_close(head_region) then
    if #lines == 0 then
      -- Empty body: keep suffix from first byte of inner (e.g. lone ">"); do not use code_inner_start-1 (duplicates a byte).
      local inner = new_inner
      if inner ~= "" and inner:sub(-1) ~= "\n" then
        inner = inner .. "\n"
      end
      local out = chunk:sub(1, code_inner_start - 1) .. inner .. chunk:sub(code_inner_start)
      return out, nil
    end
    gt_line_idx = #lines
  end
  if not gt_line_idx then
    local dump = {}
    for i = 1, math.min(#head_region, 96) do
      dump[#dump + 1] = tostring(string.byte(head_region, i))
    end
    r.ShowConsoleMsg(
      "[WhisperX word overlay] Parse fail: no '>' closer before CODEPARM.\n"
        .. "head_region len="
        .. tostring(#head_region)
        .. " bytes[1.."
        .. tostring(math.min(#head_region, 96))
        .. "]="
        .. table.concat(dump, ",")
        .. "\n"
    )
    local ex = head_region
    if #ex > 1600 then
      ex = ex:sub(1, 1600) .. "..."
    end
    return nil, "No closing '>' line before CODEPARM.", ex
  end

  -- First byte to keep: start of the CODE ">" closer line (1-based offset within head_region).
  local hpos = line_byte_start(lines, seps, gt_line_idx)
  local cend = code_inner_start + hpos - 1

  local inner = new_inner
  if inner ~= "" and inner:sub(-1) ~= "\n" then
    inner = inner .. "\n"
  end
  local out = chunk:sub(1, code_inner_start - 1) .. inner .. chunk:sub(cend)
  return out, nil
end

local function upsert_video_processor_code(item, take, eel_inner, prefer_fx_guid, add_undo)
  add_undo = add_undo ~= false
  local ok, chunk = r.GetItemStateChunk(item, "", false)
  if not ok or type(chunk) ~= "string" then
    return false, "GetItemStateChunk failed."
  end
  local newchunk, err, dbg = replace_video_processor_code(chunk, eel_inner, SENTINEL, prefer_fx_guid)
  if not newchunk then
    if dbg and dbg ~= "" then
      return false, (err or "replace failed") .. "\n\n--- excerpt (for bug reports) ---\n" .. dbg
    end
    return false, err or "replace failed"
  end
  local undo_ok = r.SetItemStateChunk(item, newchunk, add_undo)
  if not undo_ok then
    undo_ok = r.SetItemStateChunk(item, newchunk, false)
  end
  if not undo_ok then
    return false,
      string.format(
        "SetItemStateChunk failed. Chunk length %d bytes. If this persists: unlock the item/track, shorten subtitles, or reduce word count.",
        type(newchunk) == "string" and #newchunk or 0
      )
  end
  return true, nil
end

local function default_display_opts()
  return {
    preset = PRESET_WORD,
    words_per_line = 8,
    max_chars = 0,
    break_after_sentence = false,
    karaoke = false,
    layout_max_rows = 4,
    layout_line_scales = { 0.58, 2, 0.58, 1, 1, 1 },
    layout_line_rand = { 0, 0, 0, 0, 0, 0 },
    layout_line_gap = 0.1,
    layout_row_v_align = 0,
    layout_ml_row_chars = 0,
    layout_ml_row_chars_rand = 0,
    layout_ml_chars_seed = 0,
    layout_indent_step = 0,
    layout_indent_rand = 0,
    layout_indent_seed = 0,
    layout_word_scale = nil,
    anim_scope = ANIM_SCOPE_EVERY_WORD,
    anim_in_on = false,
    anim_in_type = ANIM_TYPE_FADE,
    anim_in_curve = ANIM_CURVE_LINEAR,
    anim_in_dur = 0.12,
    anim_in_amp = 1,
    anim_in_bounce = 0.7,
    anim_in_motion = 1,
    anim_in_wiggle = 1,
    anim_in_scale = 0,
    anim_in_fade = 0,
    anim_in_blur = 0,
    anim_in_ghost = 1,
    anim_in_dupes = 3,
    anim_in_dir = 90,
    anim_in_twist = 0,
    anim_in_use_graph = false,
    anim_in_graph_word_span = false,
    anim_in_graph = "0,0,0|0.65,0,1;0",
    anim_in_auto_blob = "",
    anim_out_on = false,
    anim_out_type = ANIM_TYPE_FADE,
    anim_out_curve = ANIM_CURVE_LINEAR,
    anim_out_dur = 0.12,
    anim_out_amp = 1,
    anim_phrase_out_on = false,
    anim_phrase_out_type = ANIM_TYPE_FADE,
    anim_phrase_out_curve = ANIM_CURVE_LINEAR,
    anim_phrase_out_dur = 0.12,
    anim_phrase_out_amp = 1,
    anim_out_bounce = 0.7,
    anim_out_motion = 1,
    anim_out_wiggle = 1,
    anim_out_scale = 0,
    anim_out_fade = 0,
    anim_out_blur = 0,
    anim_out_ghost = 1,
    anim_out_dupes = 3,
    anim_out_dir = 90,
    anim_out_twist = 0,
    anim_out_use_graph = false,
    anim_out_graph_word_span = false,
    anim_out_graph = "0,0,0|0.65,0,1;0",
    anim_out_auto_blob = "",
    anim_phrase_out_bounce = 0.7,
    anim_phrase_out_motion = 1,
    anim_phrase_out_wiggle = 1,
    anim_phrase_out_scale = 0,
    anim_phrase_out_fade = 0,
    anim_phrase_out_blur = 0,
    anim_phrase_out_ghost = 1,
    anim_phrase_out_dupes = 3,
    anim_phrase_out_dir = 90,
    anim_phrase_out_twist = 0,
    anim_wipe_mask_offset = 0,
    anim_phrase_out_use_graph = false,
    anim_phrase_out_graph_word_span = false,
    anim_phrase_out_graph = "0,0,0|0.65,0,1;0",
    anim_phrase_out_auto_blob = "",
    word_styles = nil,
    font_name = "",
    img_post_wave = false,
    img_post_wave_amp = 24,
    img_post_wave_len = 90,
    img_post_wave_speed = 6,
  }
end

local function default_editor_text_from_words(words)
  if not words or #words == 0 then
    return ""
  end
  local t = {}
  for i = 1, #words do
    t[i] = words[i].w
  end
  if words_use_cjk_compact_join(words) then
    return table.concat(t, "\n")
  end
  return table.concat(t, " ")
end

--- One subtitle line per run of markers until sentence punctuation or `` ` `` (see body for rules).
local function word_triggers_flat_reset_break(w)
  if type(w) ~= "string" or w == "" then
    return false
  end
  if w:find("`", 1, true) then
    return true
  end
  if w:match("…$") or w:match("%.%.%.$") then
    return true
  end
  -- Period only at end avoids breaking "3.14" mid-token; ? and ! anywhere match real markers better.
  if w:match("%.$") then
    return true
  end
  if w:find("?", 1, true) or w:find("!", 1, true) then
    return true
  end
  if w:find("？", 1, true) or w:find("！", 1, true) then
    return true
  end
  return false
end

--- Reset-style editor text: join all marker words (space for Latin, none for CJK), newline after sentence / `` ` ``.
local function editor_text_from_words_flat_until_punct(words)
  if not words or #words == 0 then
    return ""
  end
  local cjk = words_use_cjk_compact_join(words)
  local sep = cjk and "" or " "
  local lines = {}
  local buf = {}
  for i = 1, #words do
    buf[#buf + 1] = words[i].w or ""
    if word_triggers_flat_reset_break(words[i].w) then
      lines[#lines + 1] = table.concat(buf, sep)
      buf = {}
    end
  end
  if #buf > 0 then
    lines[#lines + 1] = table.concat(buf, sep)
  end
  return table.concat(lines, "\n")
end

--- Insert newlines from slider rules (original marker spellings). Does not change word text.
local OVERLAY_UI_EXT_SECTION = "BRYAN_WX_OVERLAY_UI"

--- Combo index as stored by the bridge (0 = Word … 3 = Triple). Legacy 4 still maps to triple (stairs removed from UI).
local function overlay_preset_from_combo_index(idx)
  idx = math.floor(tonumber(idx) or 0)
  if idx == 1 then
    return PRESET_LINE_FULL
  end
  if idx == 2 then
    return PRESET_LINE_GROW
  end
  if idx == 3 or idx == 4 then
    return PRESET_LINE_TRIPLE
  end
  return PRESET_WORD
end

local function ext_bool_section(section, key, default_true)
  local s = r.GetExtState(section, key)
  if s == nil or s == "" then
    return default_true
  end
  local sl = s:lower()
  if s == "0" or sl == "false" or sl == "off" or sl == "no" then
    return false
  end
  return true
end

local function video_guides_from_extstate(section)
  local defs = {
    { key = "VIDEO_GUIDE_169", label = "16:9", ratio = 16 / 9, color = 0x00E5FF },
    { key = "VIDEO_GUIDE_916", label = "9:16", ratio = 9 / 16, color = 0xFF66CC },
    { key = "VIDEO_GUIDE_11", label = "1:1", ratio = 1, color = 0xFFD447 },
    { key = "VIDEO_GUIDE_45", label = "4:5", ratio = 4 / 5, color = 0x66FF66 },
    { key = "VIDEO_GUIDE_43", label = "4:3", ratio = 4 / 3, color = 0xAA88FF },
    { key = "VIDEO_GUIDE_235", label = "2.35:1", ratio = 2.35, color = 0xFF8844 },
  }
  local out = {}
  for _, guide in ipairs(defs) do
    if ext_bool_section(section, guide.key, false) then
      out[#out + 1] = { label = guide.label, ratio = guide.ratio, color = guide.color }
    end
  end
  return (#out > 0) and out or nil
end

--- `@*` escapes in optional `font_name` field (last `:`-delimited field) so `:`/`;`/`@` survive blob storage.
local function word_style_font_blob_unesc(s)
  if type(s) ~= "string" or s == "" then
    return ""
  end
  return s:gsub("@S", ";"):gsub("@C", ":"):gsub("@@", "@")
end

local function word_styles_from_blob(blob)
  local out = {}
  if type(blob) ~= "string" or blob == "" then
    return nil
  end
  for rec in blob:gmatch("[^;]+") do
    local parts = {}
    local i = 1
    while i <= #rec + 1 do
      local j = rec:find(":", i, true)
      if not j then
        parts[#parts + 1] = rec:sub(i)
        break
      end
      parts[#parts + 1] = rec:sub(i, j - 1)
      i = j + 1
    end
    local wi = tonumber(parts[1])
    local flags = parts[2]
    local textc = parts[3]
    local highc = parts[4]
    wi = tonumber(wi)
    if wi and wi >= 1 then
      local st = { flags = math.max(0, math.floor(tonumber(flags) or 0)) }
      local tc = tonumber(textc)
      if tc then
        st.text_color = math.max(0, math.min(0xFFFFFF, math.floor(tc)))
      end
      local hc = tonumber(highc)
      if hc then
        st.highlight_color = math.max(0, math.min(0xFFFFFF, math.floor(hc)))
      end
      st.pseudo_bold_copies = tonumber(parts[5])
      st.pseudo_bold_offset = tonumber(parts[6])
      st.pseudo_slant = tonumber(parts[7])
      st.shadow_dx = tonumber(parts[8])
      st.shadow_dy = tonumber(parts[9])
      st.shadow_alpha = tonumber(parts[10])
      st.underline_thick = tonumber(parts[11])
      st.underline_offset = tonumber(parts[12])
      st.anim_preset_name = tostring(parts[13] or ""):match("^%s*(.-)%s*$")
      st.outline_thickness = tonumber(parts[14])
      st.outline_gap = tonumber(parts[15])
      local oc = tonumber(parts[16])
      if oc then
        st.outline_color = math.max(0, math.min(0xFFFFFF, math.floor(oc)))
      end
      st.font_name = word_style_font_blob_unesc(parts[17] or "")
      if st.flags ~= 0 or st.text_color ~= nil or st.highlight_color ~= nil or st.anim_preset_name ~= "" or trim_display_line(st.font_name or "") ~= "" then
        out[wi] = st
      end
    end
  end
  return next(out) and out or nil
end

local function word_styles_from_extstate(section)
  return word_styles_from_blob(r.GetExtState(section, "WORD_STYLE_BLOB"))
end

local function word_styles_from_item(item)
  if not item or not r.GetSetMediaItemInfo_String then
    return nil
  end
  local ok, blob = r.GetSetMediaItemInfo_String(item, OVERLAY_ITEM_EXT_WORD_STYLES, "", false)
  if not ok or type(blob) ~= "string" or blob == "" then
    return nil
  end
  return word_styles_from_blob(blob)
end

local function word_styles_for_display_opts(section, item)
  if item then
    return word_styles_from_item(item)
  end
  return word_styles_from_extstate(section)
end

local function row_gap_from_item(item)
  if not item or not r.GetSetMediaItemInfo_String then
    return nil
  end
  local ok, blob = r.GetSetMediaItemInfo_String(item, OVERLAY_ITEM_EXT_ROW_SPACING, "", false)
  if not ok or type(blob) ~= "string" or blob == "" then
    return nil
  end
  local out = {}
  for tok in string.gmatch(blob, "[^\031]+") do
    local k, v = tostring(tok):match("^(%d+):([%-%d%.eE]+)$")
    k, v = tonumber(k), tonumber(v)
    if k and v and k >= 1 then
      out[k] = math.max(-0.95, math.min(1.5, v))
    end
  end
  return next(out) and out or nil
end

--- `ML_PHRASE_AFTER` / `ML_ROW_AFTER` extstate strings are `"0"`/`"1"` of length `#words - 1` (bit i = after word i).
local function overlay_ml_after_tables_for_word_count(section, n_words)
  if type(n_words) ~= "number" or n_words < 1 then
    return nil, nil
  end
  local pa = r.GetExtState(section, "ML_PHRASE_AFTER") or ""
  local ra = r.GetExtState(section, "ML_ROW_AFTER") or ""
  local pa_t, ra_t = {}, {}
  for i = 1, math.max(0, n_words - 1) do
    pa_t[i] = string.sub(pa, i, i) == "1"
    ra_t[i] = string.sub(ra, i, i) == "1"
  end
  return pa_t, ra_t
end

--- Build display_opts from bridge extstate (same keys as WhisperX word overlay bridge). Optional `section` override.
--- When `item` is set, per-word styles come only from that item's P_EXT blob (not global extstate).
--- Optional `n_words`: when set (e.g. `#words`), parses `ML_PHRASE_AFTER` / `ML_ROW_AFTER` into `display_opts.ml_*` for triple/stairs CJK parse.
local function overlay_display_opts_from_extstate(section, item, n_words)
  section = (type(section) == "string" and section ~= "" and section) or OVERLAY_UI_EXT_SECTION
  --- Always triple-stack layout in UI; legacy PRESET_IDX / KARAOKE migrate into SHOW_WORDS_MODE.
  local ml_timing_mode = math.floor(tonumber(r.GetExtState(section, "SHOW_WORDS_MODE")) or -1)
  if ml_timing_mode < 0 or ml_timing_mode > 2 then
    local idx = math.floor(tonumber(r.GetExtState(section, "PRESET_IDX")) or 3)
    if idx == 4 then
      idx = 3
    end
    idx = math.max(0, math.min(4, idx))
    local karaoke_legacy = ext_bool_section(section, "KARAOKE", true)
    if idx == 0 then
      ml_timing_mode = 2
    elseif karaoke_legacy then
      ml_timing_mode = 0
    else
      ml_timing_mode = 1
    end
  end
  ml_timing_mode = math.max(0, math.min(2, ml_timing_mode))
  local karaoke = ml_timing_mode ~= 1
  local wpl = math.max(1, math.min(64, math.floor(tonumber(r.GetExtState(section, "WORDS_PER_LINE")) or 8)))
  local mx = math.max(0, math.min(500, math.floor(tonumber(r.GetExtState(section, "MAX_CHARS")) or 0)))
  local brk = ext_bool_section(section, "BREAK_SENTENCE", false)
  local et = r.GetExtState(section, "EDITOR_TEXT")
  local ml_def = { 0.58, 2, 0.58, 1, 1, 1 }
  local ml_max = math.max(1, math.min(6, math.floor(tonumber(r.GetExtState(section, "ML_MAX_ROWS")) or 4)))
  local ls, lr = {}, {}
  for i = 1, 6 do
    local d = ml_def[i] or 1
    ls[i] = math.max(0.12, math.min(3, tonumber(r.GetExtState(section, "ML_S" .. tostring(i))) or d))
    lr[i] = math.max(0, math.min(1, tonumber(r.GetExtState(section, "ML_R" .. tostring(i))) or 0))
  end
  local jj, any_j = {}, false
  for i = 1, 6 do
    local js = r.GetExtState(section, "ML_J" .. tostring(i))
    if type(js) == "string" and js ~= "" then
      jj[i] = tonumber(js) or 0
      any_j = true
    end
  end
  if any_j then
    for i = 1, 6 do
      jj[i] = tonumber(jj[i]) or 0
    end
  else
    jj = nil
  end
  local ml_pa, ml_ra = overlay_ml_after_tables_for_word_count(section, n_words)
  return {
    preset = PRESET_LINE_TRIPLE,
    words_per_line = wpl,
    max_chars = mx,
    break_after_sentence = brk,
    editor_text = et,
    karaoke = karaoke,
    ml_timing_mode = ml_timing_mode,
    layout_max_rows = ml_max,
    layout_line_scales = ls,
    layout_line_rand = lr,
    layout_line_gap = math.max(-0.95, math.min(0.5, tonumber(r.GetExtState(section, "ML_LINE_GAP")) or 0.1)),
    layout_row_v_align = math.max(0, math.min(2, math.floor(tonumber(r.GetExtState(section, "ML_ROW_VALIGN")) or 0))),
    layout_rand_jitter = jj,
    layout_ml_row_chars = math.max(0, math.min(500, math.floor(tonumber(r.GetExtState(section, "ML_ROW_CHARS")) or 0))),
    layout_ml_row_chars_rand = math.max(0, math.min(200, math.floor(tonumber(r.GetExtState(section, "ML_ROW_CHARS_RAND")) or 0))),
    layout_ml_chars_seed = tonumber(r.GetExtState(section, "ML_CHARS_SEED")) or 0,
    layout_indent_step = math.max(0, math.min(0.5, tonumber(r.GetExtState(section, "ML_INDENT_STEP")) or 0)),
    layout_indent_rand = math.max(0, math.min(0.25, tonumber(r.GetExtState(section, "ML_INDENT_RAND")) or 0)),
    layout_indent_seed = tonumber(r.GetExtState(section, "ML_INDENT_SEED")) or 0,
    layout_row_gap = row_gap_from_item(item),
    ml_phrase_after = ml_pa,
    ml_row_after = ml_ra,
    layout_word_scale = nil,
    video_guides = video_guides_from_extstate(section),
    anim_scope = math.max(
      ANIM_SCOPE_EVERY_WORD,
      math.min(ANIM_SCOPE_ROW_FIRST, math.floor(tonumber(r.GetExtState(section, "ANIM_SCOPE")) or ANIM_SCOPE_EVERY_WORD))
    ),
    anim_in_on = ext_bool_section(section, "ANIM_IN_ON", false),
    anim_in_type = math.max(
      ANIM_TYPE_NONE,
      math.min(ANIM_TYPE_LAST, migrate_anim_type_id(math.floor(tonumber(r.GetExtState(section, "ANIM_IN_TYPE")) or ANIM_TYPE_FADE), section))
    ),
    anim_in_curve = math.max(
      ANIM_CURVE_LINEAR,
      math.min(ANIM_CURVE_ELASTIC, math.floor(tonumber(r.GetExtState(section, "ANIM_IN_CURVE")) or ANIM_CURVE_LINEAR))
    ),
    anim_in_dur = math.max(0, math.min(2.0, tonumber(r.GetExtState(section, "ANIM_IN_DUR")) or 0.12)),
    anim_in_amp = math.max(0, math.min(3.0, tonumber(r.GetExtState(section, "ANIM_IN_AMP")) or 1)),
    anim_in_bounce = math.max(0, math.min(2.0, tonumber(r.GetExtState(section, "ANIM_IN_BOUNCE")) or tonumber(r.GetExtState(section, "ANIM_BOUNCE")) or 0.7)),
    anim_in_motion = math.max(0, math.min(3.0, tonumber(r.GetExtState(section, "ANIM_IN_MOTION")) or tonumber(r.GetExtState(section, "ANIM_MOTION")) or 1)),
    anim_in_wiggle = math.max(0, math.min(3.0, tonumber(r.GetExtState(section, "ANIM_IN_WIGGLE")) or tonumber(r.GetExtState(section, "ANIM_WIGGLE")) or 1)),
    anim_in_scale = math.max(-1.0, math.min(2.0, tonumber(r.GetExtState(section, "ANIM_IN_SCALE")) or 0)),
    anim_in_fade = math.max(0, math.min(1.0, tonumber(r.GetExtState(section, "ANIM_IN_FADE")) or 0)),
    anim_in_blur = math.max(0, math.min(3.0, tonumber(r.GetExtState(section, "ANIM_IN_BLUR")) or 0)),
    anim_in_ghost = math.max(0, math.min(2.0, tonumber(r.GetExtState(section, "ANIM_IN_GHOST")) or tonumber(r.GetExtState(section, "ANIM_GHOST")) or 1)),
    anim_in_dupes = math.max(1, math.min(ANIM_MAX_DUPES, math.floor(tonumber(r.GetExtState(section, "ANIM_IN_DUPES")) or 3))),
    anim_in_dir = math.max(-180, math.min(180, tonumber(r.GetExtState(section, "ANIM_IN_DIR")) or 90)),
    anim_in_twist = math.max(-720, math.min(720, tonumber(r.GetExtState(section, "ANIM_IN_TWIST")) or 0)),
    anim_in_use_graph = ext_bool_section(section, "ANIM_IN_USE_GRAPH", false),
    anim_in_graph_word_span = ext_bool_section(section, "ANIM_IN_GRAPH_WORD_SPAN", false),
    anim_in_graph = (function()
      local g = r.GetExtState(section, "ANIM_IN_GRAPH")
      if type(g) == "string" and g ~= "" then
        return g
      end
      return "0,0,0|0.65,0,1;0"
    end)(),
    anim_in_auto_blob = r.GetExtState(section, "ANIM_IN_GRAPH_AUTO"),
    anim_out_on = ext_bool_section(section, "ANIM_OUT_ON", false),
    anim_out_type = math.max(
      ANIM_TYPE_NONE,
      math.min(ANIM_TYPE_LAST, migrate_anim_type_id(math.floor(tonumber(r.GetExtState(section, "ANIM_OUT_TYPE")) or ANIM_TYPE_FADE), section))
    ),
    anim_out_curve = math.max(
      ANIM_CURVE_LINEAR,
      math.min(ANIM_CURVE_ELASTIC, math.floor(tonumber(r.GetExtState(section, "ANIM_OUT_CURVE")) or ANIM_CURVE_LINEAR))
    ),
    anim_out_dur = math.max(0, math.min(2.0, tonumber(r.GetExtState(section, "ANIM_OUT_DUR")) or 0.12)),
    anim_out_amp = math.max(0, math.min(3.0, tonumber(r.GetExtState(section, "ANIM_OUT_AMP")) or 1)),
    anim_phrase_out_on = ext_bool_section(section, "ANIM_PHRASE_OUT_ON", false),
    anim_phrase_out_type = math.max(
      ANIM_TYPE_NONE,
      math.min(
        ANIM_TYPE_LAST,
        migrate_anim_type_id(
          math.floor(
            tonumber(r.GetExtState(section, "ANIM_PHRASE_OUT_TYPE"))
              or tonumber(r.GetExtState(section, "ANIM_OUT_TYPE"))
              or ANIM_TYPE_FADE
          ),
          section
        )
      )
    ),
    anim_phrase_out_curve = math.max(
      ANIM_CURVE_LINEAR,
      math.min(ANIM_CURVE_ELASTIC, math.floor(tonumber(r.GetExtState(section, "ANIM_PHRASE_OUT_CURVE")) or tonumber(r.GetExtState(section, "ANIM_OUT_CURVE")) or ANIM_CURVE_LINEAR))
    ),
    anim_phrase_out_dur = math.max(0, math.min(2.0, tonumber(r.GetExtState(section, "ANIM_PHRASE_OUT_DUR")) or tonumber(r.GetExtState(section, "ANIM_OUT_DUR")) or 0.12)),
    anim_phrase_out_amp = math.max(0, math.min(3.0, tonumber(r.GetExtState(section, "ANIM_PHRASE_OUT_AMP")) or tonumber(r.GetExtState(section, "ANIM_OUT_AMP")) or 1)),
    anim_out_bounce = math.max(0, math.min(2.0, tonumber(r.GetExtState(section, "ANIM_OUT_BOUNCE")) or tonumber(r.GetExtState(section, "ANIM_BOUNCE")) or 0.7)),
    anim_out_motion = math.max(0, math.min(3.0, tonumber(r.GetExtState(section, "ANIM_OUT_MOTION")) or tonumber(r.GetExtState(section, "ANIM_MOTION")) or 1)),
    anim_out_wiggle = math.max(0, math.min(3.0, tonumber(r.GetExtState(section, "ANIM_OUT_WIGGLE")) or tonumber(r.GetExtState(section, "ANIM_WIGGLE")) or 1)),
    anim_out_scale = math.max(-1.0, math.min(2.0, tonumber(r.GetExtState(section, "ANIM_OUT_SCALE")) or 0)),
    anim_out_fade = math.max(0, math.min(1.0, tonumber(r.GetExtState(section, "ANIM_OUT_FADE")) or 0)),
    anim_out_blur = math.max(0, math.min(3.0, tonumber(r.GetExtState(section, "ANIM_OUT_BLUR")) or 0)),
    anim_out_ghost = math.max(0, math.min(2.0, tonumber(r.GetExtState(section, "ANIM_OUT_GHOST")) or tonumber(r.GetExtState(section, "ANIM_GHOST")) or 1)),
    anim_out_dupes = math.max(1, math.min(ANIM_MAX_DUPES, math.floor(tonumber(r.GetExtState(section, "ANIM_OUT_DUPES")) or 3))),
    anim_out_dir = math.max(-180, math.min(180, tonumber(r.GetExtState(section, "ANIM_OUT_DIR")) or 90)),
    anim_out_twist = math.max(-720, math.min(720, tonumber(r.GetExtState(section, "ANIM_OUT_TWIST")) or 0)),
    anim_out_use_graph = ext_bool_section(section, "ANIM_OUT_USE_GRAPH", false),
    anim_out_graph_word_span = ext_bool_section(section, "ANIM_OUT_GRAPH_WORD_SPAN", false),
    anim_out_graph = (function()
      local g = r.GetExtState(section, "ANIM_OUT_GRAPH")
      if type(g) == "string" and g ~= "" then
        return g
      end
      return "0,0,0|0.65,0,1;0"
    end)(),
    anim_out_auto_blob = r.GetExtState(section, "ANIM_OUT_GRAPH_AUTO"),
    anim_phrase_out_bounce = math.max(0, math.min(2.0, tonumber(r.GetExtState(section, "ANIM_PHRASE_OUT_BOUNCE")) or tonumber(r.GetExtState(section, "ANIM_OUT_BOUNCE")) or tonumber(r.GetExtState(section, "ANIM_BOUNCE")) or 0.7)),
    anim_phrase_out_motion = math.max(0, math.min(3.0, tonumber(r.GetExtState(section, "ANIM_PHRASE_OUT_MOTION")) or tonumber(r.GetExtState(section, "ANIM_OUT_MOTION")) or tonumber(r.GetExtState(section, "ANIM_MOTION")) or 1)),
    anim_phrase_out_wiggle = math.max(0, math.min(3.0, tonumber(r.GetExtState(section, "ANIM_PHRASE_OUT_WIGGLE")) or tonumber(r.GetExtState(section, "ANIM_OUT_WIGGLE")) or tonumber(r.GetExtState(section, "ANIM_WIGGLE")) or 1)),
    anim_phrase_out_scale = math.max(-1.0, math.min(2.0, tonumber(r.GetExtState(section, "ANIM_PHRASE_OUT_SCALE")) or tonumber(r.GetExtState(section, "ANIM_OUT_SCALE")) or 0)),
    anim_phrase_out_fade = math.max(0, math.min(1.0, tonumber(r.GetExtState(section, "ANIM_PHRASE_OUT_FADE")) or tonumber(r.GetExtState(section, "ANIM_OUT_FADE")) or 0)),
    anim_phrase_out_blur = math.max(0, math.min(3.0, tonumber(r.GetExtState(section, "ANIM_PHRASE_OUT_BLUR")) or tonumber(r.GetExtState(section, "ANIM_OUT_BLUR")) or 0)),
    anim_phrase_out_ghost = math.max(0, math.min(2.0, tonumber(r.GetExtState(section, "ANIM_PHRASE_OUT_GHOST")) or tonumber(r.GetExtState(section, "ANIM_OUT_GHOST")) or tonumber(r.GetExtState(section, "ANIM_GHOST")) or 1)),
    anim_phrase_out_dupes = math.max(1, math.min(ANIM_MAX_DUPES, math.floor(tonumber(r.GetExtState(section, "ANIM_PHRASE_OUT_DUPES")) or tonumber(r.GetExtState(section, "ANIM_OUT_DUPES")) or 3))),
    anim_phrase_out_dir = math.max(-180, math.min(180, tonumber(r.GetExtState(section, "ANIM_PHRASE_OUT_DIR")) or tonumber(r.GetExtState(section, "ANIM_OUT_DIR")) or 90)),
    anim_wipe_mask_offset = math.max(-300, math.min(300, tonumber(r.GetExtState(section, "ANIM_WIPE_MASK_OFFSET")) or 0)),
    anim_phrase_out_twist = math.max(
      -720,
      math.min(
        720,
        tonumber(r.GetExtState(section, "ANIM_PHRASE_OUT_TWIST")) or tonumber(r.GetExtState(section, "ANIM_OUT_TWIST")) or 0
      )
    ),
    anim_phrase_out_use_graph = ext_bool_section(section, "ANIM_PHRASE_OUT_USE_GRAPH", false),
    anim_phrase_out_graph_word_span = ext_bool_section(section, "ANIM_PHRASE_OUT_GRAPH_WORD_SPAN", false),
    anim_phrase_out_graph = (function()
      local g = r.GetExtState(section, "ANIM_PHRASE_OUT_GRAPH")
      if type(g) == "string" and g ~= "" then
        return g
      end
      local g2 = r.GetExtState(section, "ANIM_OUT_GRAPH")
      if type(g2) == "string" and g2 ~= "" then
        return g2
      end
      return "0,0,0|0.65,0,1;0"
    end)(),
    anim_phrase_out_auto_blob = (function()
      local s = r.GetExtState(section, "ANIM_PHRASE_OUT_GRAPH_AUTO")
      if type(s) == "string" and s ~= "" then
        return s
      end
      return r.GetExtState(section, "ANIM_OUT_GRAPH_AUTO")
    end)(),
    word_styles = word_styles_for_display_opts(section, item),
    font_name = trim_display_line(r.GetExtState(section, "FONT_NAME") or ""),
    img_post_wave = ext_bool_section(section, "IMG_POST_WAVE", false),
    img_post_wave_amp = math.max(0, math.min(240, tonumber(r.GetExtState(section, "IMG_POST_WAVE_AMP")) or 24)),
    img_post_wave_len = math.max(8, math.min(2000, tonumber(r.GetExtState(section, "IMG_POST_WAVE_LEN")) or 90)),
    img_post_wave_speed = math.max(-20, math.min(20, tonumber(r.GetExtState(section, "IMG_POST_WAVE_SPEED")) or 6)),
  }
end

--- Fingerprint marker times + spellings for live-sync scripts (order-sensitive), plus draft editor helpers.
--- Packaged in one table to stay under Lua's 200 top-level locals per chunk.
local _wx_overlay_tail = {
  overlay_marker_signature = function(words)
    if not words or #words == 0 then
      return ""
    end
    local parts = {}
    for i = 1, #words do
      parts[#parts + 1] = string.format("%.17g", words[i].t) .. "\031" .. tostring(words[i].w or "")
    end
    return table.concat(parts, "\030")
  end,
  draft_editor_text_from_sliders = function(words, display_opts)
    display_opts = display_opts or {}
    if not words or #words == 0 then
      return ""
    end
    local lines = split_words_into_lines(
      words,
      display_opts.words_per_line,
      display_opts.max_chars,
      display_opts.break_after_sentence and true or false
    )
    local sep = words_use_cjk_compact_join(words) and "" or " "
    local parts = {}
    for i = 1, #lines do
      parts[#parts + 1] = join_words_range(lines[i], 1, #lines[i], sep)
    end
    return table.concat(parts, "\n")
  end,
}

return {
  READ_MARKER_WORDS_AS_IS = READ_MARKER_WORDS_AS_IS,
  migrate_anim_type_id = migrate_anim_type_id,
  migrate_anim_type_compact_to_v3 = migrate_anim_type_compact_to_v3,
  SENTINEL = SENTINEL,
  MAX_WORDS = MAX_WORDS,
  PRESET_WORD = PRESET_WORD,
  PRESET_LINE_FULL = PRESET_LINE_FULL,
  PRESET_LINE_GROW = PRESET_LINE_GROW,
  PRESET_LINE_TRIPLE = PRESET_LINE_TRIPLE,
  PRESET_LINE_STAIRS = PRESET_LINE_STAIRS,
  default_display_opts = default_display_opts,
  find_take_and_wx_words = find_take_and_wx_words,
  source_length_for_take = source_length_for_take,
  build_eel_body = build_eel_body,
  build_display_segments = build_display_segments,
  parse_editor_line_groups = parse_editor_line_groups,
  parse_editor_phrases_for_multiline = parse_editor_phrases_for_multiline,
  normalize_editor_text_for_overlay = normalize_editor_text_for_overlay,
  strip_overlay_grave = strip_overlay_grave,
  words_use_cjk_compact_join = words_use_cjk_compact_join,
  default_editor_text_from_words = default_editor_text_from_words,
  editor_text_from_words_flat_until_punct = editor_text_from_words_flat_until_punct,
  draft_editor_text_from_sliders = _wx_overlay_tail.draft_editor_text_from_sliders,
  editor_text_from_ml_after_flags = editor_text_from_ml_after_flags,
  split_words_into_lines = split_words_into_lines,
  eel_plain_to_reaper_vp_chunk = eel_plain_to_reaper_vp_chunk,
  upsert_video_processor_code = upsert_video_processor_code,
  get_take_marker_srcpos_name = get_take_marker_srcpos_name,
  overlay_display_opts_from_extstate = overlay_display_opts_from_extstate,
  OVERLAY_ITEM_EXT_WORD_STYLES = OVERLAY_ITEM_EXT_WORD_STYLES,
  OVERLAY_ITEM_EXT_ROW_SPACING = OVERLAY_ITEM_EXT_ROW_SPACING,
  overlay_marker_signature = _wx_overlay_tail.overlay_marker_signature,
  overlay_preset_from_combo_index = overlay_preset_from_combo_index,
}
