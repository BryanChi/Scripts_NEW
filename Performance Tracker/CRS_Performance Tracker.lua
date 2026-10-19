-- @description Performance Tracker (frame time and CPU share of running CRS scripts)
-- @author Bryan Chi
-- @version 1.0
-- @provides [nomain] CRS_Perf.lua
-- @about
--   Shows how long each frame of every running script takes, how much of REAPER's time it uses
--   and a history graph. Scripts take part by wrapping their defer loop with CRS_Perf.Wrap
--   (FX Devices, Vertical FX List, Sample Map, Stem Split). They only start measuring while this
--   window is open.

local r = reaper
if not r.ImGui_GetBuiltinPath then
  r.ShowMessageBox('ReaImGui v0.9+ is required.', 'Performance Tracker', 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local im = require 'imgui' '0.9.3'

local SECTION = 'CRS_PerfTracker'
local SCRIPT_PATH = debug.getinfo(1, 'S').source:gsub('^@', '')
local DIR = SCRIPT_PATH:match('^(.*[/\\])') or ''
local MAX_SAMPLES = 4000 -- per script; a minute at REAPER's defer rate with room to spare
local STALE_AFTER = 1.5  -- seconds without a publish: shown as stopped

-- the scripts' copies of CRS_Perf.lua register this window as an action from this path
r.SetExtState(SECTION, 'tracker_path', SCRIPT_PATH, true)

local S = {
  scripts = {},       -- name -> { work = {}, gap = {}, n = 0, head = 0, seq = -1, last = 0, mem = 0 }
  order = {},
  selected = nil,     -- nil: every script on the graph
  window_s = 10,
  budget_ms = 10,
  paused = false,
  last_hb = 0,
}

local COL = {
  text_dim = 0x9A9A9AFF,
  ok = 0x6CC28AFF,
  warn = 0xE0B050FF,
  bad = 0xE06060FF,
  bg = 0x1C1C1EFF,
  grid = 0xFFFFFF22,
  budget = 0xE0606099,
  gap = 0x80B0FF88,
}
local SERIES = { 0x6CC28AFF, 0x80B0FFFF, 0xE0B050FF, 0xD080E0FF, 0x60D0D0FF, 0xF09060FF }

local function script(name)
  local s = S.scripts[name]
  if not s then
    s = { work = {}, gap = {}, n = 0, head = 0, seq = -1, last = 0, mem = 0, missing = 0 }
    S.scripts[name] = s
    S.order[#S.order + 1] = name
    table.sort(S.order, function(a, b) return a:lower() < b:lower() end)
  end
  return s
end

local function push(s, work, gap)
  s.head = s.head % MAX_SAMPLES + 1
  s.work[s.head], s.gap[s.head] = work, gap
  if s.n < MAX_SAMPLES then s.n = s.n + 1 end
end

-- i = 0 is the newest sample
local function at(s, i)
  local k = (s.head - 1 - i) % MAX_SAMPLES + 1
  return s.work[k], s.gap[k]
end

local function read_all()
  local now = r.time_precise()
  for name in r.GetExtState(SECTION, 'list'):gmatch('[^\n]+') do
    local s = script(name)
    local raw = r.GetExtState(SECTION, 'd:' .. name)
    local seq, t, mem, body = raw:match('^(%d+)|([%d%.]+)|(%d+)|(.*)$')
    seq = tonumber(seq)
    if seq and seq ~= s.seq then
      if s.seq >= 0 and seq > s.seq + 1 then s.missing = s.missing + (seq - s.seq - 1) end
      s.seq, s.last, s.mem = seq, tonumber(t) or now, tonumber(mem) or 0
      if not S.paused then
        for w, g in body:gmatch('([%d%.]+),([%d%.]+)') do push(s, tonumber(w), tonumber(g)) end
      end
    end
    s.running = seq ~= nil and (now - s.last) < STALE_AFTER
  end
end

-- stats over the samples covering the last window_s seconds
local function stats(s)
  local sum_w, sum_g, max_w, cnt, over = 0, 0, 0, 0, 0
  local limit = S.window_s * 1000
  local vals = {}
  for i = 0, s.n - 1 do
    local w, g = at(s, i)
    if sum_g + g > limit and cnt > 0 then break end
    sum_w, sum_g, cnt = sum_w + w, sum_g + g, cnt + 1
    if w > max_w then max_w = w end
    if w > S.budget_ms then over = over + 1 end
    vals[cnt] = w
  end
  if cnt == 0 then return nil end
  table.sort(vals)
  local last = at(s, 0)
  return {
    last = last,
    avg = sum_w / cnt,
    p95 = vals[math.max(1, math.ceil(cnt * 0.95))],
    max = max_w,
    cpu = sum_g > 0 and (sum_w / sum_g * 100) or 0,
    fps = sum_g > 0 and (cnt / sum_g * 1000) or 0,
    gap_avg = sum_g / cnt,
    over = over,
    count = cnt,
  }
end

local function ms_color(v)
  if v > S.budget_ms then return COL.bad end
  if v > S.budget_ms * 0.5 then return COL.warn end
  return COL.ok
end

local function cell_ms(v)
  im.TableNextColumn(ctx)
  if v then im.TextColored(ctx, ms_color(v), string.format('%.2f', v)) else im.TextDisabled(ctx, '-') end
end

local function draw_table(all_stats)
  local flags = im.TableFlags_RowBg | im.TableFlags_BordersInnerV | im.TableFlags_SizingStretchProp
  if not im.BeginTable(ctx, 'scripts', 10, flags) then return end
  im.TableSetupColumn(ctx, 'Script', im.TableColumnFlags_WidthStretch, 2.2)
  for _, h in ipairs({ 'Last ms', 'Avg ms', 'p95 ms', 'Max ms', 'CPU %', 'FPS', 'Gap ms', 'Over', 'Lua MB' }) do
    im.TableSetupColumn(ctx, h, im.TableColumnFlags_WidthStretch, 1)
  end
  im.TableHeadersRow(ctx)

  local tot_cpu = 0
  for idx, name in ipairs(S.order) do
    local s, st = S.scripts[name], all_stats[name]
    im.TableNextRow(ctx)
    im.TableNextColumn(ctx)
    im.PushStyleColor(ctx, im.Col_Text, s.running and SERIES[(idx - 1) % #SERIES + 1] or COL.text_dim)
    if im.Selectable(ctx, (s.running and '' or '(stopped) ') .. name .. '##' .. name, S.selected == name,
        im.SelectableFlags_SpanAllColumns) then
      S.selected = S.selected ~= name and name or nil
    end
    im.PopStyleColor(ctx)
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, 'Click to graph only this script (click again for all).'
        .. (s.missing > 0 and ('\n' .. s.missing .. ' batch(es) missed while this window was busy.') or ''))
    end
    if st then
      if s.running then tot_cpu = tot_cpu + st.cpu end
      cell_ms(st.last) cell_ms(st.avg) cell_ms(st.p95) cell_ms(st.max)
      im.TableNextColumn(ctx) im.Text(ctx, string.format('%.1f', st.cpu))
      im.TableNextColumn(ctx) im.Text(ctx, string.format('%.0f', st.fps))
      im.TableNextColumn(ctx)
      im.TextColored(ctx, st.gap_avg > 50 and COL.warn or COL.text_dim, string.format('%.1f', st.gap_avg))
      im.TableNextColumn(ctx)
      im.TextColored(ctx, st.over > 0 and COL.bad or COL.text_dim, tostring(st.over))
    else
      for _ = 1, 8 do im.TableNextColumn(ctx) im.TextDisabled(ctx, '-') end
    end
    im.TableNextColumn(ctx) im.Text(ctx, string.format('%.1f', s.mem / 1024))
  end
  im.EndTable(ctx)
  if #S.order == 0 then
    im.TextDisabled(ctx, 'Waiting for scripts... Start FX Devices, Vertical FX List, Sample Map or Stem Split.')
  else
    im.Text(ctx, string.format('All running scripts: %.1f%% of REAPER\'s main thread', tot_cpu))
  end
end

local function draw_graph(all_stats)
  local x, y = im.GetCursorScreenPos(ctx)
  local w, h = im.GetContentRegionAvail(ctx)
  h = math.max(80, h)
  im.InvisibleButton(ctx, 'graph', math.max(1, w), h)
  local hovered = im.IsItemHovered(ctx)
  local dl = im.GetWindowDrawList(ctx)
  im.DrawList_AddRectFilled(dl, x, y, x + w, y + h, COL.bg, 4)

  -- vertical scale: the biggest frame on screen, at least twice the budget
  local top = S.budget_ms * 2
  for name, st in pairs(all_stats) do
    if (not S.selected or S.selected == name) and st.max > top then top = st.max end
  end
  top = top * 1.1
  local function Y(ms) return y + h - math.min(ms, top) / top * (h - 14) end

  for _, frac in ipairs({ 0.25, 0.5, 0.75 }) do
    local gy = Y(top * frac)
    im.DrawList_AddLine(dl, x, gy, x + w, gy, COL.grid)
    im.DrawList_AddText(dl, x + 4, gy - 13, COL.text_dim, string.format('%.1f ms', top * frac))
  end
  local by = Y(S.budget_ms)
  im.DrawList_AddLine(dl, x, by, x + w, by, COL.budget, 1.5)
  im.DrawList_AddText(dl, x + w - 90, by - 13, COL.budget, string.format('budget %.0f ms', S.budget_ms))

  -- x axis is time (newest on the right), so scripts running at different rates line up
  local span = S.window_s * 1000
  local tip
  local mx, my = im.GetMousePos(ctx)
  for idx, name in ipairs(S.order) do
    local s = S.scripts[name]
    if (not S.selected or S.selected == name) and s.n > 0 then
      local clr = SERIES[(idx - 1) % #SERIES + 1]
      local tx = 0
      local px, py
      for i = 0, s.n - 1 do
        local wv, g = at(s, i)
        local sx = x + w - tx / span * w
        if sx < x then break end
        local sy = Y(wv)
        if S.selected then -- one script: a bar per frame, red over budget, and the frame gap as a line
          local bw = math.max(1, g / span * w - 0.5)
          im.DrawList_AddRectFilled(dl, sx - bw, sy, sx, y + h, ms_color(wv) & 0xFFFFFFCC)
          local gy = Y(g)
          if px then im.DrawList_AddLine(dl, px, py, sx, gy, COL.gap) end
          px, py = sx, gy
          if hovered and mx <= sx and mx > sx - math.max(bw, 2) then
            tip = string.format('%s\nframe %.2f ms\ngap since previous frame %.1f ms\n%.1f s ago', name, wv, g, tx / 1000)
          end
        else
          if px then im.DrawList_AddLine(dl, px, py, sx, sy, clr, 1.2) end
          px, py = sx, sy
          if hovered and not tip and math.abs(mx - sx) < 2 and math.abs(my - sy) < 6 then
            tip = string.format('%s\nframe %.2f ms\n%.1f s ago', name, wv, tx / 1000)
          end
        end
        tx = tx + g
      end
    end
  end
  if tip then im.SetTooltip(ctx, tip) end
end

local function frame()
  local now = r.time_precise()
  if now - S.last_hb > 0.25 then
    r.SetExtState(SECTION, 'hb', string.format('%.3f', now), false)
    S.last_hb = now
  end
  read_all()

  im.SetNextWindowSize(ctx, 760, 460, im.Cond_FirstUseEver)
  local visible, open = im.Begin(ctx, 'Performance Tracker', true)
  if visible then
    local all_stats = {}
    for name, s in pairs(S.scripts) do all_stats[name] = stats(s) end

    if im.Button(ctx, S.paused and 'Resume' or 'Pause') then S.paused = not S.paused end
    im.SameLine(ctx)
    if im.Button(ctx, 'Clear') then
      for _, s in pairs(S.scripts) do s.n, s.head, s.missing = 0, 0, 0 end
    end
    im.SameLine(ctx)
    im.SetNextItemWidth(ctx, 140)
    local _
    _, S.window_s = im.SliderDouble(ctx, 'History (s)', S.window_s, 2, 60, '%.0f')
    im.SameLine(ctx)
    im.SetNextItemWidth(ctx, 140)
    _, S.budget_ms = im.SliderDouble(ctx, 'Budget (ms)', S.budget_ms, 1, 50, '%.0f')
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, 'Frames slower than this count as Over and show red.\nREAPER runs script loops about every 33 ms; every script and REAPER\'s own UI share that time.')
    end

    draw_table(all_stats)
    im.Spacing(ctx)
    im.TextDisabled(ctx, S.selected and (S.selected .. ': frame time per frame, blue line = gap between frames')
      or 'Frame time of every script (click a row to see one)')
    draw_graph(all_stats)
    im.End(ctx)
  end
  if open then
    r.defer(frame)
  end
end

ctx = im.CreateContext('Performance Tracker')
r.atexit(function() r.DeleteExtState(SECTION, 'hb', false) end)

-- the tracker measures itself too
local ok, Perf = pcall(dofile, DIR .. 'CRS_Perf.lua')
if ok and type(Perf) == 'table' then frame = Perf.Wrap('Performance Tracker', frame) end
r.defer(frame)
