-- Duplicate and pool automation item to selected tracks
--
-- Behavior:
-- - Uses the currently selected envelope and the selected automation item on it
-- - Inserts pooled automation items for the same parameter on all other selected tracks
-- - If a target track does not have a matching envelope, that track is skipped

local function err(msg)
  reaper.ShowMessageBox(msg, "Duplicate & Pool AI", 0)
end

local function getSelectedEnvelope()
  return reaper.GetSelectedEnvelope(0)
end

local function getSelectedAutomationItemIndex(env)
  local aiCount = reaper.CountAutomationItems(env)
  for aiIdx = 0, aiCount - 1 do
    local selected = reaper.GetSetAutomationItemInfo(env, aiIdx, "D_UISEL", 0, false)
    if selected and selected > 0.5 then
      return aiIdx
    end
  end
  return -1
end

local function copyAIProps(srcEnv, srcIdx, dstEnv, dstIdx)
  -- Copy common properties to keep behavior consistent
  local props = {
    "D_STARTOFFS",
    "D_PLAYRATE",
    "D_LOOPSRC",
    "D_FADEINLEN",
    "D_FADEOUTLEN",
    -- Add more keys here if needed in the future
  }

  for i = 1, #props do
    local key = props[i]
    local val = reaper.GetSetAutomationItemInfo(srcEnv, srcIdx, key, 0, false)
    if val ~= nil then
      reaper.GetSetAutomationItemInfo(dstEnv, dstIdx, key, val, true)
    end
  end
end

local function main()
  local env = getSelectedEnvelope()
  if not env then
    err("No envelope selected.")
    return
  end

  local srcTrack = reaper.Envelope_GetParentTrack(env)
  if not srcTrack then
    err("Could not determine parent track of the selected envelope.")
    return
  end

  local aiIdx = getSelectedAutomationItemIndex(env)
  if aiIdx < 0 then
    err("No automation item is selected on the active envelope.")
    return
  end

  local ok, envName = reaper.GetEnvelopeName(env)
  if not ok or not envName or envName == "" then
    err("Failed to get envelope name.")
    return
  end

  -- Gather source AI properties
  local pos     = reaper.GetSetAutomationItemInfo(env, aiIdx, "D_POSITION", 0, false)
  local length  = reaper.GetSetAutomationItemInfo(env, aiIdx, "D_LENGTH", 0, false)
  local poolId  = reaper.GetSetAutomationItemInfo(env, aiIdx, "D_POOL_ID", 0, false)

  if not pos or not length or not poolId then
    err("Failed to read automation item properties.")
    return
  end

  -- In practice, automation items should always have a pool id >= 0.
  if poolId < 0 then
    err("Selected automation item has no pool. Pool it first, then retry.")
    return
  end

  local numSel = reaper.CountSelectedTracks(0)
  if numSel <= 0 then
    err("No tracks are selected.")
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local created = 0
  local skippedMissingEnv = {}

  for i = 0, numSel - 1 do
    local tr = reaper.GetSelectedTrack(0, i)
    if tr ~= nil and tr ~= srcTrack then
      local targetEnv = reaper.GetTrackEnvelopeByName(tr, envName)
      if targetEnv then
        local newIdx = reaper.InsertAutomationItem(targetEnv, poolId, pos, length)
        if newIdx >= 0 then
          copyAIProps(env, aiIdx, targetEnv, newIdx)
          reaper.Envelope_SortPointsEx(targetEnv, -1)
          created = created + 1
        end
      else
        skippedMissingEnv[#skippedMissingEnv + 1] = tr
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Duplicate & pool AI to selected tracks", -1)

  if created == 0 then
    if #skippedMissingEnv > 0 then
      err("No pooled items created. Matching envelopes not found on the other selected tracks.")
    else
      err("No pooled items created (no eligible target tracks).")
    end
  end
end

main()


