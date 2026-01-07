-- Smart Remove Items Overlap
-- Analyzes overlapping portions between selected items on the same track
-- and removes the overlapping segment from the item that contains less
-- information in that region.

local proj = 0

local EPS = 1e-9
local MAX_AUDIO_SAMPLES = 20000

local function getItemTimes(item)
	local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
	local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
	return pos, pos + len
end

local function itemsOverlap(a, b)
	local as, ae = getItemTimes(a)
	local bs, be = getItemTimes(b)
	local s = math.max(as, bs)
	local e = math.min(ae, be)
	if e - s > EPS then
		return true, s, e
	end
	return false, 0, 0
end

local function getActiveTake(item)
	local take = reaper.GetActiveTake(item)
	if take and reaper.ValidatePtr2(proj, take, "MediaItem_Take*") then
		return take
	end
	return nil
end

local function isTakeMIDI(take)
	if not take then return false end
	return reaper.TakeIsMIDI(take)
end

local function isItemOrTakeMuted(item, take)
	if reaper.GetMediaItemInfo_Value(item, "B_MUTE") > 0.5 then return true end
	if take and reaper.GetMediaItemTakeInfo_Value(take, "B_MUTE") > 0.5 then return true end
	return false
end

-- MIDI: compute fraction of the overlap time where at least one note is sounding
local function midiCoverageFraction(take, tStart, tEnd)
	if not take then return 0.0 end
	local ok, noteCount, _, _ = reaper.MIDI_CountEvts(take)
	if not ok or noteCount == 0 then return 0.0 end
	local overlapDur = math.max(0, tEnd - tStart)
	if overlapDur <= 0 then return 0.0 end

	-- Accumulate total covered time by union of note intervals within [tStart, tEnd]
	local intervals = {}
	for i = 0, noteCount - 1 do
		local rv, _, _, startppq, endppq, _, _, _ = reaper.MIDI_GetNote(take, i)
		if rv then
			local ns = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
			local ne = reaper.MIDI_GetProjTimeFromPPQPos(take, endppq)
			if ne < ns then ns, ne = ne, ns end
			local s = math.max(ns, tStart)
			local e = math.min(ne, tEnd)
			if e - s > EPS then
				intervals[#intervals+1] = {s, e}
			end
		end
	end

	if #intervals == 0 then return 0.0 end

	-- Merge intervals
	table.sort(intervals, function(a, b) return a[1] < b[1] end)
	local merged = {}
	local curS, curE = intervals[1][1], intervals[1][2]
	for i = 2, #intervals do
		local s, e = intervals[i][1], intervals[i][2]
		if s <= curE + EPS then
			if e > curE then curE = e end
		else
			merged[#merged+1] = {curS, curE}
			curS, curE = s, e
		end
	end
	merged[#merged+1] = {curS, curE}

	local covered = 0.0
	for i = 1, #merged do
		covered = covered + (merged[i][2] - merged[i][1])
	end
	local frac = covered / overlapDur
	if frac < 0 then frac = 0 end
	if frac > 1 then frac = 1 end
	return frac
end

-- Audio: approximate RMS over [tStart, tEnd] using an AudioAccessor
local function audioRMSFraction(take, tStart, tEnd)
	if not take then return 0.0 end
	local accessor = reaper.CreateTakeAudioAccessor(take)
	if not accessor then return 0.0 end
	local dur = math.max(0, tEnd - tStart)
	if dur <= 0 then reaper.DestroyAudioAccessor(accessor) return 0.0 end

	-- Determine sample count and effective sample rate to cap total samples
	local desired = math.floor(22050 * dur)
	local total = math.max(1, math.min(MAX_AUDIO_SAMPLES, desired))
	local effSR = math.max(1000, math.floor(total / dur))
	local numCh = 2
	local buf = reaper.new_array(total * numCh)

	local ok = reaper.AudioAccessorGetSamples(accessor, effSR, numCh, tStart, total, buf)
	if not ok then
		reaper.DestroyAudioAccessor(accessor)
		buf.clear(buf)
		return 0.0
	end

	-- Compute RMS across channels
	local sumSq = 0.0
	local count = 0
	for i = 0, total - 1 do
		for c = 0, numCh - 1 do
			local sample = buf[(i * numCh) + c]
			sumSq = sumSq + (sample * sample)
			count = count + 1
		end
	end
	buf.clear(buf)
	reaper.DestroyAudioAccessor(accessor)
	if count == 0 then return 0.0 end
	local rms = math.sqrt(sumSq / count)
	-- Clamp to [0,1]
	if rms < 0 then rms = 0 end
	if rms > 1 then rms = 1 end
	return rms
end

local function computeInfoScore(item, tStart, tEnd)
	local take = getActiveTake(item)
	if not take then return 0.0 end
	if isItemOrTakeMuted(item, take) then return 0.0 end
	if isTakeMIDI(take) then
		return midiCoverageFraction(take, tStart, tEnd)
	else
		return audioRMSFraction(take, tStart, tEnd)
	end
end

local function deleteRangeFromItem(item, tStart, tEnd)
	local track = reaper.GetMediaItem_Track(item)
	local iStart, iEnd = getItemTimes(item)
	local s = math.max(iStart, tStart)
	local e = math.min(iEnd, tEnd)
	if e - s <= EPS then return false end

	-- Entire item is within delete range
	if s <= iStart + EPS and e >= iEnd - EPS then
		reaper.DeleteTrackMediaItem(track, item)
		return true
	end

	-- Overlap touches start edge only
	if s <= iStart + EPS then
		local rightAfter = reaper.SplitMediaItem(item, e)
		if rightAfter then
			reaper.DeleteTrackMediaItem(track, item)
			return true
		end
		return false
	end

	-- Overlap touches end edge only
	if e >= iEnd - EPS then
		local rightPart = reaper.SplitMediaItem(item, s)
		if rightPart then
			reaper.DeleteTrackMediaItem(track, rightPart)
			return true
		end
		return false
	end

	-- Overlap strictly inside -> split twice and delete the middle piece
	local right1 = reaper.SplitMediaItem(item, s)
	if not right1 then return false end
	local right2 = reaper.SplitMediaItem(right1, e)
	-- right1 is now the middle segment [s, e]
	local ok = reaper.DeleteTrackMediaItem(track, right1)
	return ok
end

local function getSelectedItems()
	local t = {}
	local cnt = reaper.CountSelectedMediaItems(proj)
	for i = 0, cnt - 1 do
		local it = reaper.GetSelectedMediaItem(proj, i)
		if it then t[#t+1] = it end
	end
	return t
end

local function groupItemsByTrack(items)
	local groups = {}
	for i = 1, #items do
		local it = items[i]
		local tr = reaper.GetMediaItem_Track(it)
		local key = tostring(tr)
		if not groups[key] then groups[key] = { track = tr, items = {} } end
		groups[key].items[#groups[key].items+1] = it
	end
	return groups
end

local function sortItemsByPos(items)
	table.sort(items, function(a, b)
		local as = reaper.GetMediaItemInfo_Value(a, "D_POSITION")
		local bs = reaper.GetMediaItemInfo_Value(b, "D_POSITION")
		if as == bs then
			local al = reaper.GetMediaItemInfo_Value(a, "D_LENGTH")
			local bl = reaper.GetMediaItemInfo_Value(b, "D_LENGTH")
			return al < bl
		end
		return as < bs
	end)
end

local function processTrackGroup(group)
	local changed = false
	local items = {}
	for i = 1, #group.items do items[i] = group.items[i] end
	sortItemsByPos(items)
	for i = 1, #items - 1 do
		local a = items[i]
		local b = items[i+1]
		if reaper.ValidatePtr2(proj, a, "MediaItem*") and reaper.ValidatePtr2(proj, b, "MediaItem*") then
			local ov, s, e = itemsOverlap(a, b)
			if ov then
				-- New condition: ignore pairs where one item is fully contained in the other
				local as, ae = getItemTimes(a)
				local bs, be = getItemTimes(b)
				local aInsideB = (as > bs + EPS) and (ae < be - EPS)
				local bInsideA = (bs > as + EPS) and (be < ae - EPS)
				if not (aInsideB or bInsideA) then
					local infoA = computeInfoScore(a, s, e)
					local infoB = computeInfoScore(b, s, e)
					-- Resolve tie by preferring the later item to be trimmed (keeps earlier intact)
					local removeFromA = (infoA < infoB) or (math.abs(infoA - infoB) <= 1e-6)
					if removeFromA then
						if deleteRangeFromItem(a, s, e) then changed = true end
					else
						if deleteRangeFromItem(b, s, e) then changed = true end
					end
				end
			end
		end
	end
	return changed
end

local function smartRemoveOverlaps()
	local iterations = 0
	local changedAny = false
	repeat
		iterations = iterations + 1
		local selected = getSelectedItems()
		if #selected < 2 then break end
		local groups = groupItemsByTrack(selected)
		local changed = false
		for _, group in pairs(groups) do
			if group.track and reaper.ValidatePtr2(proj, group.track, "MediaTrack*") then
				if processTrackGroup(group) then changed = true end
			end
		end
		if changed then changedAny = true end
	until not changed or iterations > 50
	return changedAny
end

reaper.Undo_BeginBlock2(proj)
reaper.PreventUIRefresh(1)
local ok, err = pcall(function()
	local did = smartRemoveOverlaps()
	if did then
		reaper.UpdateArrange()
	end
end)
reaper.PreventUIRefresh(-1)
if ok then
	reaper.Undo_EndBlock2(proj, "Smart Remove Items Overlap", -1)
else
	reaper.Undo_EndBlock2(proj, "Smart Remove Items Overlap (failed)", -1)
end


