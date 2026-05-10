-- @description Revert render item to previous version (GUI)
-- @version 1.1
-- @author Bryan
-- @about
--   ReaImGui browser for render-history snapshots on the selected item.
--   Select a saved version (including original) and restore it.

local r = reaper

local HISTORY_SECTION = "BRYAN_RENDER_ITEM_HISTORY"
local WINDOW_TITLE = "Render History Revert"

package.path = r.ImGui_GetBuiltinPath() .. "/?.lua"
local ok_imgui, ImGui = pcall(function() return require("imgui")("0.9.3") end)
if not ok_imgui then
  ok_imgui, ImGui = pcall(function() return require("imgui")("0.9.2") end)
end
if not ok_imgui then
  r.MB("ReaImGui is required for this script.", "Revert render version", 0)
  return
end

local function split_string(s, sep)
  local out = {}
  if not s or s == "" then return out end
  local start = 1
  while true do
    local i, j = s:find(sep, start, true)
    if not i then
      out[#out + 1] = s:sub(start)
      break
    end
    out[#out + 1] = s:sub(start, i - 1)
    start = j + 1
  end
  return out
end

local function decode_blob(s)
  if not s or s == "" then return "" end
  local out = {}
  local i = 1
  local n = #s
  while i <= n do
    local ch = s:sub(i, i)
    if ch == "\\" and i < n then
      local nx = s:sub(i + 1, i + 1)
      if nx == "n" then
        out[#out + 1] = "\n"
      elseif nx == "r" then
        out[#out + 1] = "\r"
      elseif nx == "t" then
        out[#out + 1] = "\t"
      elseif nx == "\\" then
        out[#out + 1] = "\\"
      else
        out[#out + 1] = nx
      end
      i = i + 2
    else
      out[#out + 1] = ch
      i = i + 1
    end
  end
  return table.concat(out)
end

local function get_item_guid(item)
  if not item then return nil end
  local ok, guid = r.GetSetMediaItemInfo_String(item, "GUID", "", false)
  if ok and guid and guid ~= "" then
    return guid
  end
  return nil
end

local function load_item_history(item_guid)
  local _, blob = r.GetProjExtState(0, HISTORY_SECTION, item_guid)
  if not blob or blob == "" then return {} end

  local rows = split_string(blob, "\n")
  local entries = {}
  for _, row in ipairs(rows) do
    if row ~= "" then
      local parts = split_string(row, "\t")
      if #parts >= 4 then
        entries[#entries + 1] = {
          ts = parts[1],
          label = parts[2],
          summary = parts[3],
          chunk = parts[4],
        }
      end
    end
  end
  return entries
end

local function clear_generated_render_markers(item)
  local take_count = r.GetMediaItemNumTakes(item) or 0
  for take_idx = 0, take_count - 1 do
    local take = r.GetMediaItemTake(item, take_idx)
    if take then
      local marker_count = r.GetNumTakeMarkers(take) or 0
      for marker_idx = marker_count - 1, 0, -1 do
        local _, marker_name = r.GetTakeMarker(take, marker_idx)
        local name = tostring(marker_name or "")
        if name == "Rendered" or name:match("^Rendered:") then
          if type(r.DeleteTakeMarker) == "function" then
            r.DeleteTakeMarker(take, marker_idx)
          else
            r.SetTakeMarker(take, marker_idx, "", -1, -1)
          end
        end
      end
    end
  end
end

local function get_selected_item_for_revert()
  local sel_count = r.CountSelectedMediaItems(0)
  if sel_count ~= 1 then
    return nil, "Select exactly one media item."
  end
  local item = r.GetSelectedMediaItem(0, 0)
  if not item then
    return nil, "No selected item found."
  end
  return item, nil
end

local item, item_err = get_selected_item_for_revert()
if not item then
  r.MB(item_err or "Selection error.", "Revert render version", 0)
  return
end

local item_guid = get_item_guid(item)
if not item_guid then
  r.MB("Could not read item GUID.", "Revert render version", 0)
  return
end

local entries = load_item_history(item_guid)
if #entries == 0 then
  r.MB("No render history found for this item yet.", "Revert render version", 0)
  return
end

local ui_entries = {}
for i = #entries, 1, -1 do
  local e = entries[i]
  ui_entries[#ui_entries + 1] = {
    history_index = i,
    is_original = (i == 1),
    label = tostring(e.label or ""),
    summary = tostring(e.summary or ""),
  }
end

local state = {
  selected_ui_index = 1,
  status = "",
  status_is_error = false,
  should_close = false,
}

local ctx = ImGui.CreateContext(WINDOW_TITLE)

local function restore_selected_version()
  local pick = ui_entries[state.selected_ui_index]
  if not pick then
    state.status = "No version selected."
    state.status_is_error = true
    return
  end

  local entry = entries[pick.history_index]
  if not entry or not entry.chunk or entry.chunk == "" then
    state.status = "Selected history entry is invalid."
    state.status_is_error = true
    return
  end

  local target_chunk = decode_blob(entry.chunk)
  if target_chunk == "" then
    state.status = "Selected history entry is empty."
    state.status_is_error = true
    return
  end

  r.Undo_BeginBlock()
  local ok = r.SetItemStateChunk(item, target_chunk, false)
  if ok and pick.is_original then
    clear_generated_render_markers(item)
  end
  r.UpdateItemInProject(item)
  r.UpdateArrange()

  if ok then
    r.Undo_EndBlock("Revert item to render history version", -1)
    state.status = "Restored: " .. (pick.label ~= "" and pick.label or "selected version")
    state.status_is_error = false
  else
    r.Undo_EndBlock("Revert item to render history version (failed)", -1)
    state.status = "Failed to restore selected history version."
    state.status_is_error = true
  end
end

local function begin_child_compat(id, w, h)
  local child_flags = ImGui.ChildFlags_Border or 0
  local ok, visible = pcall(ImGui.BeginChild, ctx, id, w, h, child_flags)
  if ok then
    return visible
  end
  ok, visible = pcall(ImGui.BeginChild, ctx, id, w, h, true)
  if ok then
    return visible
  end
  return false
end

local function draw_left_panel(height)
  if begin_child_compat("##history_list", 0, height) then
    ImGui.Text(ctx, "Saved Versions")
    ImGui.Separator(ctx)
    for i, e in ipairs(ui_entries) do
      local title = e.label ~= "" and e.label or ("Version " .. tostring(e.history_index))
      if e.is_original then
        title = title .. "  [Original]"
      end
      local summary = e.summary ~= "" and e.summary or "(no render details)"
      local row_text = title .. "\n" .. summary
      if ImGui.Selectable(ctx, row_text, state.selected_ui_index == i) then
        state.selected_ui_index = i
      end
      ImGui.Separator(ctx)
    end
    ImGui.EndChild(ctx)
  end
end

local function loop()
  local window_flags = ImGui.WindowFlags_NoCollapse
  ImGui.SetNextWindowSize(ctx, 950, 520, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, WINDOW_TITLE, true, window_flags)
  if visible then
    ImGui.Text(ctx, "Item GUID:")
    ImGui.SameLine(ctx)
    ImGui.TextColored(ctx, 0xB8B8B8FF, item_guid)
    ImGui.Separator(ctx)

    local _, avail_h = ImGui.GetContentRegionAvail(ctx)
    local content_h = math.max(220, avail_h - 72)
    draw_left_panel(content_h)

    ImGui.Separator(ctx)
    local pick = ui_entries[state.selected_ui_index]
    if pick and pick.is_original then
      ImGui.TextWrapped(ctx, "Selected: Original snapshot. Restore will also clear generated 'Rendered' take markers.")
    end
    if state.status ~= "" then
      if state.status_is_error then
        ImGui.TextColored(ctx, 0x7D7DFFFF, state.status)
      else
        ImGui.TextColored(ctx, 0x8FD18CFF, state.status)
      end
    end
    if ImGui.Button(ctx, "Restore Selected", 170, 0) then
      restore_selected_version()
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Close", 90, 0) then
      state.should_close = true
    end

    ImGui.End(ctx)
  end

  if open and not state.should_close then
    r.defer(loop)
  end
end

r.defer(loop)
